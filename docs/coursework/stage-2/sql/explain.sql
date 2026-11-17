\pset pager off
SET TIME ZONE 'Europe/Moscow';
SELECT setseed(0.42);

BEGIN;

INSERT INTO app_user (first_name, phone_number, created_at)
SELECT (ARRAY ['Алиса','Борис','Вера','Григорий','Дина','Евгений','Жанна','Захар','Ирина','Кирилл'])[1 + i % 10],
       '+7922' || lpad(i::TEXT, 7, '0'),
       now() - INTERVAL '400 days'
FROM generate_series(1, 300) AS i;

CREATE TEMP TABLE gen_client ON COMMIT DROP AS
SELECT user_id,
       substr(phone_number, 6)::INT AS no,
       CASE
           WHEN substr(phone_number, 6)::INT <= 100 THEN 'PERIOD'
           WHEN substr(phone_number, 6)::INT <= 150 THEN 'PACK'
           WHEN substr(phone_number, 6)::INT <= 180 THEN 'TRIAL'
           ELSE 'NONE' END AS kind
FROM app_user
WHERE phone_number LIKE '+7922%';

CREATE TEMP TABLE gen_training ON COMMIT DROP AS
SELECT d, s.slot_no, s.slot_time,
       (SELECT place_id FROM place WHERE is_active ORDER BY place_id OFFSET (d + 1000 + s.slot_no) % 2 LIMIT 1) AS place_id
FROM generate_series(-365, -4) AS d
         CROSS JOIN (VALUES (0, TIME '09:00'), (1, TIME '19:00')) AS s(slot_no, slot_time);

ALTER TABLE gen_training ADD COLUMN training_id INT, ADD COLUMN starts_at TIMESTAMPTZ;
UPDATE gen_training SET starts_at = (current_date + d + slot_time) AT TIME ZONE 'Europe/Moscow';

WITH ins AS (
    INSERT INTO training (place_id, name, starts_at, capacity, duration)
        SELECT place_id,
               CASE slot_no WHEN 0 THEN 'Утренний драйв' ELSE 'Сила и выносливость' END,
               starts_at, 10, CASE slot_no WHEN 0 THEN 45 ELSE 60 END
        FROM gen_training
        RETURNING training_id, starts_at)
UPDATE gen_training g
SET training_id = ins.training_id
FROM ins
WHERE ins.starts_at = g.starts_at;

INSERT INTO training_trainer (training_id, trainer_id, role)
SELECT g.training_id, a.user_id, 'LEAD'
FROM gen_training g
         JOIN (SELECT row_number() OVER (ORDER BY user_id) - 1 AS no, user_id FROM trainer WHERE is_active) a
              ON a.no = (g.d * 2 + g.slot_no + 1000) % 4;

INSERT INTO subscription (tariff_id, user_id, created_at, expires_at, visits_left, status)
SELECT t.tariff_id,
       c.user_id,
       now() - INTERVAL '370 days' + k * INTERVAL '30 days' + c.no % 30 * INTERVAL '1 day',
       now() - INTERVAL '370 days' + k * INTERVAL '30 days' + c.no % 30 * INTERVAL '1 day'
           + make_interval(days => t.duration_days),
       t.visits_count,
       'ACTIVE'
FROM gen_client c
         CROSS JOIN generate_series(0, 11) AS k
         JOIN tariff t ON t.name = CASE c.kind WHEN 'PERIOD' THEN 'Безлимит на месяц' ELSE 'Пакет 10 занятий' END
WHERE c.kind IN ('PERIOD', 'PACK');

INSERT INTO subscription (tariff_id, user_id, created_at, expires_at, visits_left, status)
SELECT t.tariff_id,
       c.user_id,
       now() - INTERVAL '360 days' + (c.no - 150) * INTERVAL '10 days',
       now() - INTERVAL '360 days' + (c.no - 150) * INTERVAL '10 days' + make_interval(days => t.duration_days),
       t.visits_count,
       'ACTIVE'
FROM gen_client c
         JOIN tariff t ON t.name = 'Разовое занятие'
WHERE c.kind = 'TRIAL';

INSERT INTO payment (subscription_id, amount, status, provider_payment_id, created_at, paid_at)
SELECT s.subscription_id, t.price, 'SUCCEEDED', 'gen-' || s.subscription_id, s.created_at, s.created_at
FROM subscription s
         JOIN gen_client c ON c.user_id = s.user_id
         JOIN tariff t ON t.tariff_id = s.tariff_id;

DO
$$
    DECLARE
        v_training RECORD;
    BEGIN
        FOR v_training IN SELECT training_id, starts_at FROM gen_training ORDER BY starts_at
            LOOP
                INSERT INTO booking (user_id, training_id, subscription_id, created_at)
                SELECT a.user_id, v_training.training_id, a.subscription_id, v_training.starts_at - INTERVAL '2 days'
                FROM (SELECT DISTINCT ON (s.user_id) s.user_id, s.subscription_id
                      FROM subscription s
                               JOIN gen_client c ON c.user_id = s.user_id
                      WHERE s.status = 'ACTIVE'
                        AND s.created_at <= v_training.starts_at - INTERVAL '2 days'
                        AND s.expires_at >= v_training.starts_at
                      ORDER BY s.user_id, s.expires_at) a
                ORDER BY random()
                LIMIT 4 + floor(random() * 7)::INT;
            END LOOP;
    END
$$;

UPDATE booking b
SET status       = 'CANCELLED',
    cancelled_at = b.created_at + INTERVAL '1 day'
FROM gen_training g
WHERE g.training_id = b.training_id
  AND random() < 0.08;

UPDATE booking b
SET status = CASE WHEN random() < 0.1 THEN 'SKIPPED' ELSE 'ATTENDED' END::booking_status
FROM gen_training g
WHERE g.training_id = b.training_id
  AND b.status = 'BOOKED';

ANALYZE;

SELECT (SELECT count(*) FROM gen_client)                                                   AS clients,
       (SELECT count(*) FROM gen_client WHERE kind = 'NONE')                                 AS without_subscription,
       (SELECT count(*) FROM gen_training)                                                   AS trainings,
       (SELECT count(*) FROM subscription s JOIN gen_client c USING (user_id))               AS subscriptions,
       (SELECT count(*) FROM booking b JOIN gen_training g USING (training_id))              AS bookings,
       (SELECT count(*) FROM booking b JOIN gen_training g USING (training_id)
        WHERE b.status = 'CANCELLED')                                                       AS cancelled;

SELECT trainer_id AS trainer, training_id AS training
FROM training_trainer
WHERE training_id = (SELECT max(training_id) FROM gen_training) \gset
SELECT user_id AS client FROM app_user WHERE phone_number = '+79220000042' \gset

\echo '=== Schedule: training_starts_at_idx, booking_training_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT t.training_id,
       t.capacity - (SELECT count(*) FROM booking b WHERE b.training_id = t.training_id AND b.status <> 'CANCELLED')
FROM training t
WHERE t.status = 'ACTIVE'
  AND t.starts_at >= now() - INTERVAL '10 days'
  AND t.starts_at < now() - INTERVAL '3 days';

\echo '=== Trainer overlap: training_period_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT t2.training_id
FROM training t1
         JOIN training_trainer tt2 ON tt2.trainer_id = :trainer AND tt2.training_id <> t1.training_id
         JOIN training t2 ON t2.training_id = tt2.training_id
WHERE t1.training_id = :training
  AND t1.status = 'ACTIVE'
  AND t2.status = 'ACTIVE'
  AND training_period(t1.starts_at, t1.duration) && training_period(t2.starts_at, t2.duration)
LIMIT 1;

\echo '=== Participants: booking_training_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT b.booking_id, u.first_name
FROM booking b
         JOIN app_user u ON u.user_id = b.user_id
WHERE b.training_id = :training
  AND b.status <> 'CANCELLED';

\echo '=== Client subscriptions: subscription_user_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT subscription_id
FROM subscription
WHERE user_id = :client
  AND status = 'ACTIVE';

DROP INDEX training_starts_at_idx, training_period_idx, booking_training_idx, subscription_user_idx;

\echo '###### Without indexes'

\echo '=== Schedule'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT t.training_id,
       t.capacity - (SELECT count(*) FROM booking b WHERE b.training_id = t.training_id AND b.status <> 'CANCELLED')
FROM training t
WHERE t.status = 'ACTIVE'
  AND t.starts_at >= now() - INTERVAL '10 days'
  AND t.starts_at < now() - INTERVAL '3 days';

\echo '=== Trainer overlap'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT t2.training_id
FROM training t1
         JOIN training_trainer tt2 ON tt2.trainer_id = :trainer AND tt2.training_id <> t1.training_id
         JOIN training t2 ON t2.training_id = tt2.training_id
WHERE t1.training_id = :training
  AND t1.status = 'ACTIVE'
  AND t2.status = 'ACTIVE'
  AND training_period(t1.starts_at, t1.duration) && training_period(t2.starts_at, t2.duration)
LIMIT 1;

\echo '=== Participants'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT b.booking_id, u.first_name
FROM booking b
         JOIN app_user u ON u.user_id = b.user_id
WHERE b.training_id = :training
  AND b.status <> 'CANCELLED';

\echo '=== Client subscriptions'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT subscription_id
FROM subscription
WHERE user_id = :client
  AND status = 'ACTIVE';

ROLLBACK;
