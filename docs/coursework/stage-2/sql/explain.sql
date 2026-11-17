\pset pager off
SET TIME ZONE 'Europe/Moscow';
SELECT setseed(0.42);

BEGIN;

INSERT INTO app_user (first_name, phone_number, created_at)
SELECT 'Клиент ' || i, '+7922' || lpad(i::TEXT, 7, '0'), now() - INTERVAL '400 days'
FROM generate_series(1, 1500) AS i;

CREATE TEMP TABLE gen_training ON COMMIT DROP AS
SELECT d, s.slot_no, p.place_no, p.place_id, s.slot_time, p.capacity
FROM generate_series(-365, -4) AS d
         CROSS JOIN (VALUES (0, TIME '08:00'), (1, TIME '12:00'), (2, TIME '19:00'), (3, TIME '21:00')) AS s(slot_no, slot_time)
         CROSS JOIN (SELECT row_number() OVER (ORDER BY place_id) - 1 AS place_no, place_id, capacity
                     FROM place
                     WHERE is_active) AS p;

ALTER TABLE gen_training ADD COLUMN training_id INT, ADD COLUMN starts_at TIMESTAMPTZ;
UPDATE gen_training SET starts_at = (current_date + d + slot_time) AT TIME ZONE 'Europe/Moscow';

WITH ins AS (
    INSERT INTO training (place_id, name, starts_at, capacity, duration)
        SELECT place_id, 'Тренировка', starts_at, capacity, 45
        FROM gen_training
        RETURNING training_id, place_id, starts_at)
UPDATE gen_training g
SET training_id = ins.training_id
FROM ins
WHERE ins.place_id = g.place_id
  AND ins.starts_at = g.starts_at;

INSERT INTO training_trainer (training_id, trainer_id, role)
SELECT g.training_id, a.user_id, 'LEAD'
FROM gen_training g
         JOIN (SELECT row_number() OVER (ORDER BY user_id) - 1 AS no, user_id FROM trainer WHERE is_active) a
              ON a.no = (g.slot_no * 2 + g.place_no + g.d + 1000) % 4;

INSERT INTO subscription (tariff_id, user_id, created_at, expires_at, status)
SELECT (SELECT tariff_id FROM tariff WHERE type = 'PERIOD' LIMIT 1),
       u.user_id,
       now() - INTERVAL '370 days' + k * INTERVAL '30 days',
       now() - INTERVAL '370 days' + (k + 1) * INTERVAL '30 days',
       'ACTIVE'
FROM app_user u
         CROSS JOIN generate_series(0, 12) AS k
WHERE u.phone_number LIKE '+7922%'
  AND (u.user_id + k) % 5 = 0;

INSERT INTO payment (subscription_id, amount, status, provider_payment_id, created_at, paid_at)
SELECT s.subscription_id, 9900, 'SUCCEEDED', 'gen-' || s.subscription_id, s.created_at, s.created_at
FROM subscription s
         JOIN app_user u ON u.user_id = s.user_id
WHERE u.phone_number LIKE '+7922%';

INSERT INTO booking (user_id, training_id, subscription_id, created_at)
SELECT x.user_id, g.training_id, x.subscription_id, g.starts_at - INTERVAL '2 days'
FROM gen_training g
         CROSS JOIN LATERAL (
    SELECT s.user_id, s.subscription_id
    FROM subscription s
    WHERE s.created_at <= g.starts_at - INTERVAL '2 days'
      AND s.expires_at >= g.starts_at
      AND s.visits_left IS NULL
      AND s.status = 'ACTIVE'
    ORDER BY random()
    LIMIT g.capacity - 2 - (g.d * 7 + g.slot_no * 3 + g.place_no + 7000) % 6
    ) x
ORDER BY g.starts_at;

ANALYZE;

SELECT count(*) AS trainings FROM training;
SELECT count(*) AS bookings FROM booking;

SELECT trainer_id AS trainer, training_id AS training
FROM training_trainer
WHERE training_id = (SELECT max(training_id) FROM gen_training) \gset
SELECT user_id AS client FROM app_user WHERE phone_number = '+79220000150' \gset

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

\echo '=== Client bookings: booking_user_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT b.booking_id, b.status, t.name, t.starts_at
FROM booking b
         JOIN training t ON t.training_id = b.training_id
WHERE b.user_id = :client
ORDER BY t.starts_at DESC;

\echo '=== Client subscriptions: subscription_user_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT subscription_id
FROM subscription
WHERE user_id = :client
  AND status = 'ACTIVE';

\echo '=== Payment history: payment_subscription_idx'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT p.*
FROM payment p
         JOIN subscription s ON s.subscription_id = p.subscription_id
WHERE s.user_id = :client
ORDER BY p.created_at DESC;

DROP INDEX training_starts_at_idx, training_period_idx, booking_training_idx,
    booking_user_idx, subscription_user_idx, payment_subscription_idx;

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

\echo '=== Client bookings'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT b.booking_id, b.status, t.name, t.starts_at
FROM booking b
         JOIN training t ON t.training_id = b.training_id
WHERE b.user_id = :client
ORDER BY t.starts_at DESC;

\echo '=== Client subscriptions'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT subscription_id
FROM subscription
WHERE user_id = :client
  AND status = 'ACTIVE';

\echo '=== Payment history'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT p.*
FROM payment p
         JOIN subscription s ON s.subscription_id = p.subscription_id
WHERE s.user_id = :client
ORDER BY p.created_at DESC;

ROLLBACK;
