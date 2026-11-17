SET TIME ZONE 'Europe/Moscow';

BEGIN;

INSERT INTO place (name, description, photo_path, address, is_active, capacity)
VALUES ('Петроградская', 'Большой зал с панорамными окнами', '/img/places/petrogradskaya.jpg',
        'Санкт-Петербург, Большой пр. П.С., 45', TRUE, 20),
       ('Васильевский', 'Зал со световым шоу', '/img/places/vasilyevsky.jpg',
        'Санкт-Петербург, 7-я линия В.О., 34', TRUE, 16),
       ('Купчино', 'Закрыт на ремонт', NULL,
        'Санкт-Петербург, Балканская пл., 5', FALSE, 12);

INSERT INTO tariff (name, type, price, visits_count, duration_days, is_active, description)
VALUES ('Разовое занятие', 'SINGLE', 900, 1, 30, TRUE, 'Одно посещение'),
       ('Пакет 5 занятий', 'PACK', 4000, 5, 60, TRUE, 'Пять посещений за два месяца'),
       ('Пакет 10 занятий', 'PACK', 7500, 10, 90, TRUE, 'Десять посещений за три месяца'),
       ('Безлимит на месяц', 'PERIOD', 9900, NULL, 30, TRUE, 'Любое число посещений в течение 30 дней'),
       ('Пакет 8 занятий', 'PACK', 6000, 8, 60, FALSE, 'Снят с продажи');

INSERT INTO document (name, file_path, version, type, is_active)
VALUES ('Правила студии', '/docs/rules-v1.pdf', 1, 'STUDIO_RULES', FALSE),
       ('Правила студии', '/docs/rules-v2.pdf', 2, 'STUDIO_RULES', TRUE),
       ('Политика обработки персональных данных', '/docs/privacy-v1.pdf', 1, 'PRIVACY', TRUE),
       ('Публичная оферта', '/docs/offer-v1.pdf', 1, 'OFFER', TRUE);

INSERT INTO app_user (first_name, phone_number, email, password_hash, vk_id, google_id, is_admin, created_at)
VALUES ('Ольга', '+79110000001', 'olga@cycle.ru', '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh', NULL, NULL, TRUE, now() - INTERVAL '90 days'),
       ('Анна', '+79110000002', 'anna@cycle.ru', '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh', NULL, NULL, FALSE, now() - INTERVAL '90 days'),
       ('Максим', '+79110000003', 'maxim@cycle.ru', '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh', NULL, NULL, FALSE, now() - INTERVAL '90 days'),
       ('Дарья', '+79110000004', 'darya@cycle.ru', '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh', NULL, NULL, FALSE, now() - INTERVAL '90 days'),
       ('Глеб', '+79110000005', 'gleb@cycle.ru', '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh', NULL, NULL, FALSE, now() - INTERVAL '90 days');

INSERT INTO trainer (user_id, description, is_active)
SELECT u.user_id, d.description, d.is_active
FROM app_user u
         JOIN (VALUES ('+79110000001', 'Основатель студии, мастер-тренер', TRUE),
                      ('+79110000002', 'Интервальные тренировки, 5 лет опыта', TRUE),
                      ('+79110000003', 'Силовые заезды и выносливость', TRUE),
                      ('+79110000004', 'Ритмичные тренировки под поп-музыку', TRUE),
                      ('+79110000005', 'Больше не работает в студии', FALSE)) AS d(phone, description, is_active)
              ON d.phone = u.phone_number;

INSERT INTO trainer_photo (trainer_id, photo_path, sort_order)
SELECT t.user_id, '/img/trainers/' || t.user_id || '-' || n || '.jpg', n
FROM trainer t
         CROSS JOIN generate_series(0, 1) AS n;

INSERT INTO app_user (first_name, phone_number, email, password_hash, vk_id, google_id, created_at)
SELECT (ARRAY ['Алиса','Борис','Вера','Григорий','Дина','Евгений','Жанна','Захар','Ирина','Кирилл',
           'Лиза','Марк','Нина','Олег','Полина','Роман','Света','Тимур','Ульяна','Фёдор'])[i],
       CASE WHEN i % 7 <> 0 THEN '+7921' || lpad(i::TEXT, 7, '0') END,
       CASE WHEN i % 3 = 0 THEN 'client' || i || '@mail.ru' END,
       CASE WHEN i % 7 <> 0 THEN '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh' END,
       CASE WHEN i % 7 = 0 THEN 100000000 + i END,
       CASE WHEN i = 11 THEN 'google-11' END,
       now() - INTERVAL '60 days' + i * INTERVAL '1 day'
FROM generate_series(1, 20) AS i;

INSERT INTO referral_link (user_id, code, created_at)
SELECT user_id, upper(substr(md5('ref' || user_id), 1, 10)), created_at
FROM app_user;

UPDATE app_user u
SET referral_link_id = r.referral_link_id
FROM app_user inviter
         JOIN referral_link r ON r.user_id = inviter.user_id
WHERE inviter.phone_number = '+79210000001'
  AND u.phone_number IN ('+79210000002', '+79210000003');

INSERT INTO user_consent (document_id, user_id, accepted_at)
SELECT d.document_id, u.user_id, u.created_at
FROM app_user u
         JOIN document d ON d.is_active OR (d.version = 1 AND d.type = 'STUDIO_RULES' AND u.is_admin);

INSERT INTO payment_method (user_id, provider_method_id, type, title, is_active, created_at)
SELECT u.user_id, 'pm-' || u.user_id, m.type, m.title, m.is_active, u.created_at
FROM app_user u
         JOIN (VALUES ('+79210000001', 'BANK_CARD'::payment_method_type, 'Bank card *4417', TRUE),
                      ('+79210000002', 'SBP'::payment_method_type, 'СБП', TRUE),
                      ('+79210000004', 'SBERBANK'::payment_method_type, 'SberPay', TRUE),
                      ('+79210000005', 'BANK_CARD'::payment_method_type, 'Bank card *1290', FALSE)) AS m(phone, type, title, is_active)
              ON m.phone = u.phone_number;


CREATE TEMP TABLE gen_training AS
SELECT d, s.slot_no, p.place_no, p.place_id, s.slot_name, s.slot_duration,
       (current_date + d + s.slot_time) AT TIME ZONE 'Europe/Moscow' AS starts_at,
       p.capacity - 8 + (d + 10 + s.slot_no) % 3 * 2 AS capacity
FROM generate_series(-3, 3) AS d
         CROSS JOIN (VALUES (0, TIME '09:00', 'Утренний драйв', 45),
                            (1, TIME '19:00', 'Сила и выносливость', 60)) AS s(slot_no, slot_time, slot_name, slot_duration)
         CROSS JOIN (SELECT row_number() OVER (ORDER BY place_id) - 1 AS place_no, place_id, capacity
                     FROM place
                     WHERE is_active) AS p;

ALTER TABLE gen_training ADD COLUMN training_id INT;

WITH ins AS (
    INSERT INTO training (place_id, name, starts_at, capacity, duration, playlist)
        SELECT place_id, slot_name, starts_at, capacity, slot_duration,
               'https://music.yandex.ru/users/cycle/playlists/' || (100 + (d + 10) % 7)
        FROM gen_training
        ORDER BY starts_at, place_id
        RETURNING training_id, place_id, starts_at)
UPDATE gen_training g
SET training_id = ins.training_id
FROM ins
WHERE ins.place_id = g.place_id
  AND ins.starts_at = g.starts_at;

CREATE TEMP TABLE active_trainer AS
SELECT row_number() OVER (ORDER BY user_id) - 1 AS no, user_id
FROM trainer
WHERE is_active;

INSERT INTO training_trainer (training_id, trainer_id, role)
SELECT g.training_id, a.user_id, 'LEAD'
FROM gen_training g
         JOIN active_trainer a ON a.no = (g.d + 10 + g.slot_no * 2 + g.place_no) % 4;

INSERT INTO training_trainer (training_id, trainer_id, role)
SELECT g.training_id, a.user_id, 'ASSISTANT'
FROM gen_training g
         JOIN active_trainer a ON a.no = (g.d + 10 + g.slot_no * 2 + g.place_no + 2) % 4
WHERE g.place_no = 0
  AND g.slot_no = 1;


INSERT INTO subscription (tariff_id, user_id, created_at, expires_at, visits_left, status)
SELECT t.tariff_id, u.user_id, now() - INTERVAL '50 days', now() - INTERVAL '20 days', NULL, 'ACTIVE'
FROM app_user u
         JOIN tariff t ON t.name = 'Безлимит на месяц'
WHERE u.phone_number LIKE '+7921%'
  AND substr(u.phone_number, 6)::INT <= 6;

INSERT INTO subscription (tariff_id, user_id, created_at, expires_at, visits_left, status)
SELECT t.tariff_id, u.user_id, now() - INTERVAL '15 days', now() + INTERVAL '15 days', NULL, 'ACTIVE'
FROM app_user u
         JOIN tariff t ON t.name = 'Безлимит на месяц'
WHERE u.user_id IN (SELECT user_id FROM app_user WHERE NOT is_admin AND user_id NOT IN (SELECT user_id FROM trainer))
  AND u.first_name NOT IN ('Ульяна', 'Фёдор');

INSERT INTO payment (subscription_id, payment_method_id, amount, status, provider_payment_id, created_at, paid_at)
SELECT s.subscription_id, pm.payment_method_id, t.price, 'SUCCEEDED',
       'yk-' || lpad(s.subscription_id::TEXT, 8, '0'), s.created_at - INTERVAL '3 minutes', s.created_at
FROM subscription s
         JOIN tariff t ON t.tariff_id = s.tariff_id
         LEFT JOIN payment_method pm ON pm.user_id = s.user_id AND pm.is_active;


INSERT INTO booking (user_id, training_id, subscription_id, created_at)
SELECT s.user_id, g.training_id, s.subscription_id, least(g.starts_at - INTERVAL '2 days', now())
FROM gen_training g
         JOIN subscription s ON s.created_at <= g.starts_at - INTERVAL '2 days'
    AND s.expires_at >= g.starts_at
    AND (s.user_id + g.d + 10 + g.slot_no * 3 + g.place_no * 5) % 6 = 0
ORDER BY g.starts_at, s.user_id;

UPDATE booking b
SET status       = 'CANCELLED',
    cancelled_at = t.starts_at - CASE WHEN b.booking_id % 2 = 0 THEN INTERVAL '2 days' ELSE INTERVAL '3 hours' END
FROM training t
WHERE t.training_id = b.training_id
  AND b.booking_id % 11 = 0;

UPDATE training
SET status = 'CANCELLED'
WHERE training_id = (SELECT training_id FROM gen_training WHERE d = -2 AND slot_no = 0 AND place_no = 1);

UPDATE booking b
SET status = CASE WHEN b.booking_id % 6 = 0 THEN 'SKIPPED' ELSE 'ATTENDED' END::booking_status
FROM training t
WHERE t.training_id = b.training_id
  AND b.status = 'BOOKED'
  AND t.starts_at < now();

INSERT INTO feedback (user_id, trainer_id, rating, description, created_at)
SELECT DISTINCT ON (b.user_id, tt.trainer_id) b.user_id, tt.trainer_id,
                                              3 + (b.user_id * 7 + tt.trainer_id) % 3,
                                              (ARRAY ['Отличная тренировка!', 'Хороший плейлист', 'Тяжело, но круто', NULL])[1 + b.user_id % 4],
                                              t.starts_at + INTERVAL '3 hours'
FROM booking b
         JOIN training t ON t.training_id = b.training_id
         JOIN training_trainer tt ON tt.training_id = b.training_id
WHERE b.status = 'ATTENDED'
  AND (b.user_id + tt.trainer_id) % 2 = 0
ORDER BY b.user_id, tt.trainer_id, t.starts_at;

COMMIT;

CALL expire_subscriptions();

DROP TABLE gen_training, active_trainer;

DO
$$
    DECLARE
        v_docs     INT[]   := ARRAY(SELECT document_id FROM document WHERE is_active);
        v_code     VARCHAR := (SELECT r.code FROM referral_link r JOIN app_user u USING (user_id) WHERE u.phone_number = '+79210000004');
        v_admin    INT     := (SELECT user_id FROM app_user WHERE phone_number = '+79110000001');
        v_user     INT;
        v_buy      RECORD;
        v_training INT;
        v_booking  INT;
    BEGIN
        v_user := register_user('Мирон', '+79990000001', 'miron@mail.ru',
                                '$2a$10$hashhashhashhashhashhashhashhashhashhashhashhashhashh',
                                NULL, NULL, v_code, v_docs);
        SELECT * INTO v_buy FROM buy_tariff(v_user, (SELECT tariff_id FROM tariff WHERE name = 'Пакет 5 занятий'));
        PERFORM confirm_payment(v_buy.payment_id, 'yk-demo-0001');

        FOR v_training IN SELECT training_id
                          FROM training
                          WHERE status = 'ACTIVE'
                            AND starts_at > now() + INTERVAL '2 days'
                          ORDER BY starts_at
                          LIMIT 3
            LOOP
                PERFORM book_training(v_user, v_training);
            END LOOP;
        SELECT booking_id INTO v_booking FROM booking WHERE user_id = v_user ORDER BY booking_id DESC LIMIT 1;
        PERFORM cancel_booking(v_booking, v_user);

        v_user := register_user('Софья', NULL, 'sofya@gmail.com', NULL, NULL, 'google-sofya', NULL, v_docs);
        PERFORM buy_tariff(v_user, (SELECT tariff_id FROM tariff WHERE name = 'Безлимит на месяц'));

        v_user := (SELECT user_id FROM app_user WHERE first_name = 'Ульяна');
        PERFORM grant_subscription(v_admin, v_user, (SELECT tariff_id FROM tariff WHERE name = 'Разовое занятие'));

        v_user := (SELECT user_id FROM app_user WHERE first_name = 'Фёдор');
        SELECT * INTO v_buy FROM buy_tariff(v_user, (SELECT tariff_id FROM tariff WHERE name = 'Пакет 10 занятий'));
        PERFORM confirm_payment(v_buy.payment_id, 'yk-demo-0002');
        PERFORM book_training(v_user, (SELECT training_id
                                       FROM training
                                       WHERE status = 'ACTIVE' AND starts_at > now()
                                       ORDER BY starts_at DESC
                                       LIMIT 1));
        PERFORM refund_payment(v_buy.payment_id, 3750);
    END
$$;
