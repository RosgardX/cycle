CREATE FUNCTION register_user(
    p_first_name    VARCHAR,
    p_phone_number  VARCHAR,
    p_email         VARCHAR,
    p_password_hash VARCHAR,
    p_vk_id         BIGINT,
    p_google_id     VARCHAR,
    p_referral_code VARCHAR,
    p_document_ids  INT[]
) RETURNS INT
    LANGUAGE plpgsql AS
$$
DECLARE
    v_user_id          INT;
    v_referral_link_id INT;
BEGIN
    IF EXISTS (SELECT 1
               FROM document
               WHERE is_active
                 AND document_id <> ALL (coalesce(p_document_ids, '{}'))) THEN
        RAISE EXCEPTION 'All active documents must be accepted';
    END IF;

    SELECT referral_link_id
    INTO v_referral_link_id
    FROM referral_link
    WHERE code = p_referral_code
      AND is_active;

    INSERT INTO app_user (first_name, phone_number, email, password_hash, vk_id, google_id, referral_link_id)
    VALUES (p_first_name, p_phone_number, p_email, p_password_hash, p_vk_id, p_google_id, v_referral_link_id)
    RETURNING user_id INTO v_user_id;

    INSERT INTO referral_link (user_id, code)
    VALUES (v_user_id, upper(substr(md5(gen_random_uuid()::TEXT), 1, 10)));

    INSERT INTO user_consent (document_id, user_id)
    SELECT document_id, v_user_id
    FROM document
    WHERE is_active
      AND document_id = ANY (p_document_ids);

    RETURN v_user_id;
END;
$$;


CREATE FUNCTION get_schedule(
    p_from       TIMESTAMPTZ,
    p_to         TIMESTAMPTZ,
    p_place_id   INT DEFAULT NULL,
    p_trainer_id INT DEFAULT NULL
)
    RETURNS TABLE
            (
                training_id  INT,
                name         VARCHAR,
                starts_at    TIMESTAMPTZ,
                duration     INT,
                place_name   VARCHAR,
                lead_trainer VARCHAR,
                free_seats   INT
            )
    LANGUAGE sql
    STABLE AS
$$
SELECT t.training_id,
       t.name,
       t.starts_at,
       t.duration,
       p.name,
       u.first_name,
       t.capacity - (SELECT count(*)::INT
                     FROM booking b
                     WHERE b.training_id = t.training_id
                       AND b.status <> 'CANCELLED')
FROM training t
         JOIN place p ON p.place_id = t.place_id
         JOIN training_trainer lt ON lt.training_id = t.training_id AND lt.role = 'LEAD'
         JOIN app_user u ON u.user_id = lt.trainer_id
WHERE t.status = 'ACTIVE'
  AND t.starts_at >= p_from
  AND t.starts_at < p_to
  AND (p_place_id IS NULL OR t.place_id = p_place_id)
  AND (p_trainer_id IS NULL OR EXISTS (SELECT 1
                                       FROM training_trainer tt
                                       WHERE tt.training_id = t.training_id
                                         AND tt.trainer_id = p_trainer_id))
ORDER BY t.starts_at
$$;


CREATE FUNCTION book_training(
    p_user_id         INT,
    p_training_id     INT,
    p_subscription_id INT DEFAULT NULL
) RETURNS INT
    LANGUAGE plpgsql AS
$$
DECLARE
    v_starts_at       TIMESTAMPTZ;
    v_subscription_id INT := p_subscription_id;
    v_booking_id      INT;
BEGIN
    SELECT starts_at INTO v_starts_at FROM training WHERE training_id = p_training_id;
    IF v_starts_at IS NULL THEN
        RAISE EXCEPTION 'Training % not found', p_training_id;
    END IF;
    IF v_starts_at <= now() THEN
        RAISE EXCEPTION 'Training % has already started', p_training_id;
    END IF;

    IF EXISTS (SELECT 1
               FROM booking
               WHERE user_id = p_user_id
                 AND training_id = p_training_id
                 AND status <> 'CANCELLED') THEN
        RAISE EXCEPTION 'User % is already booked on training %', p_user_id, p_training_id;
    END IF;

    IF v_subscription_id IS NULL THEN
        SELECT subscription_id
        INTO v_subscription_id
        FROM subscription
        WHERE user_id = p_user_id
          AND status = 'ACTIVE'
          AND (expires_at IS NULL OR expires_at >= v_starts_at)
        ORDER BY expires_at NULLS LAST, subscription_id
        LIMIT 1;

        IF v_subscription_id IS NULL THEN
            RAISE EXCEPTION 'User % has no active subscription', p_user_id;
        END IF;
    END IF;

    INSERT INTO booking (user_id, training_id, subscription_id)
    VALUES (p_user_id, p_training_id, v_subscription_id)
    RETURNING booking_id INTO v_booking_id;

    RETURN v_booking_id;
END;
$$;


CREATE FUNCTION cancel_booking(p_booking_id INT, p_user_id INT) RETURNS BOOLEAN
    LANGUAGE plpgsql AS
$$
DECLARE
    v_booking   booking%ROWTYPE;
    v_starts_at TIMESTAMPTZ;
BEGIN
    SELECT * INTO v_booking FROM booking WHERE booking_id = p_booking_id FOR UPDATE;
    IF v_booking.user_id IS DISTINCT FROM p_user_id THEN
        RAISE EXCEPTION 'Booking % not found', p_booking_id;
    END IF;
    IF v_booking.status <> 'BOOKED' THEN
        RAISE EXCEPTION 'Booking % cannot be cancelled', p_booking_id;
    END IF;

    SELECT starts_at INTO v_starts_at FROM training WHERE training_id = v_booking.training_id;
    IF v_starts_at <= now() THEN
        RAISE EXCEPTION 'Training has already started';
    END IF;

    UPDATE booking
    SET status       = 'CANCELLED',
        cancelled_at = now()
    WHERE booking_id = p_booking_id;

    RETURN now() <= v_starts_at - booking_cancel_window();
END;
$$;


CREATE FUNCTION create_payment(
    p_subscription_id   INT,
    p_payment_method_id INT DEFAULT NULL,
    OUT payment_id      INT,
    OUT idempotence_key UUID
)
    LANGUAGE plpgsql AS
$$
DECLARE
    v_status subscription_status;
    v_price  NUMERIC(10, 2);
BEGIN
    SELECT s.status, t.price
    INTO v_status, v_price
    FROM subscription s
             JOIN tariff t ON t.tariff_id = s.tariff_id
    WHERE s.subscription_id = p_subscription_id
        FOR UPDATE OF s;

    IF v_status IS DISTINCT FROM 'PENDING' THEN
        RAISE EXCEPTION 'Subscription % is not waiting for payment', p_subscription_id;
    END IF;

    SELECT p.payment_id, p.idempotence_key
    INTO payment_id, idempotence_key
    FROM payment p
    WHERE p.subscription_id = p_subscription_id
      AND p.status = 'PENDING';

    IF payment_id IS NULL THEN
        INSERT INTO payment (subscription_id, payment_method_id, amount)
        VALUES (p_subscription_id, p_payment_method_id, v_price)
        RETURNING payment.payment_id, payment.idempotence_key INTO payment_id, idempotence_key;
    END IF;
END;
$$;


CREATE FUNCTION buy_tariff(
    p_user_id           INT,
    p_tariff_id         INT,
    p_payment_method_id INT DEFAULT NULL,
    OUT subscription_id INT,
    OUT payment_id      INT,
    OUT idempotence_key UUID
)
    LANGUAGE plpgsql AS
$$
DECLARE
    v_tariff tariff%ROWTYPE;
BEGIN
    SELECT * INTO v_tariff FROM tariff WHERE tariff_id = p_tariff_id;
    IF NOT coalesce(v_tariff.is_active, FALSE) THEN
        RAISE EXCEPTION 'Tariff % is not on sale', p_tariff_id;
    END IF;
    IF v_tariff.price = 0 THEN
        RAISE EXCEPTION 'Tariff % is free and cannot be paid', p_tariff_id;
    END IF;

    PERFORM 1 FROM app_user WHERE user_id = p_user_id FOR UPDATE;

    SELECT s.subscription_id
    INTO subscription_id
    FROM subscription s
    WHERE s.user_id = p_user_id
      AND s.tariff_id = p_tariff_id
      AND s.status = 'PENDING'
    ORDER BY s.created_at DESC
    LIMIT 1;

    IF subscription_id IS NULL THEN
        INSERT INTO subscription (tariff_id, user_id, visits_left, status)
        VALUES (p_tariff_id, p_user_id, v_tariff.visits_count, 'PENDING')
        RETURNING subscription.subscription_id INTO subscription_id;
    END IF;

    SELECT cp.payment_id, cp.idempotence_key
    INTO payment_id, idempotence_key
    FROM create_payment(subscription_id, p_payment_method_id) cp;
END;
$$;


CREATE FUNCTION confirm_payment(p_payment_id INT, p_provider_payment_id VARCHAR) RETURNS BOOLEAN
    LANGUAGE plpgsql AS
$$
DECLARE
    v_payment          payment%ROWTYPE;
    v_tariff           tariff%ROWTYPE;
    v_user_id          INT;
    v_referral_link_id INT;
    v_inviter_id       INT;
    v_reward_id        INT;
    v_reward_days      INT;
BEGIN
    SELECT * INTO v_payment FROM payment WHERE payment_id = p_payment_id FOR UPDATE;
    IF v_payment.status = 'SUCCEEDED' THEN
        RETURN FALSE;
    END IF;
    IF v_payment.status IS DISTINCT FROM 'PENDING' THEN
        RAISE EXCEPTION 'Payment % is not pending', p_payment_id;
    END IF;

    UPDATE payment
    SET status              = 'SUCCEEDED',
        paid_at             = now(),
        provider_payment_id = p_provider_payment_id
    WHERE payment_id = p_payment_id;

    SELECT t.*
    INTO v_tariff
    FROM subscription s
             JOIN tariff t ON t.tariff_id = s.tariff_id
    WHERE s.subscription_id = v_payment.subscription_id;

    UPDATE subscription
    SET status     = 'ACTIVE',
        created_at = now(),
        expires_at = now() + make_interval(days => v_tariff.duration_days)
    WHERE subscription_id = v_payment.subscription_id
    RETURNING user_id INTO v_user_id;

    SELECT referral_link_id INTO v_referral_link_id FROM app_user WHERE user_id = v_user_id;

    IF v_referral_link_id IS NOT NULL
        AND (SELECT count(*)
             FROM payment p
                      JOIN subscription s ON s.subscription_id = p.subscription_id
             WHERE s.user_id = v_user_id
               AND p.status IN ('SUCCEEDED', 'REFUNDED')) = 1 THEN

        SELECT user_id INTO v_inviter_id FROM referral_link WHERE referral_link_id = v_referral_link_id;

        SELECT tariff_id, duration_days
        INTO v_reward_id, v_reward_days
        FROM tariff
        WHERE type = 'SINGLE'
        ORDER BY is_active DESC, price
        LIMIT 1;

        IF v_reward_id IS NOT NULL THEN
            INSERT INTO subscription (tariff_id, user_id, expires_at, visits_left, status)
            VALUES (v_reward_id, v_inviter_id, now() + make_interval(days => v_reward_days), 1, 'ACTIVE');
        END IF;
    END IF;

    RETURN TRUE;
END;
$$;


CREATE FUNCTION cancel_payment(p_payment_id INT) RETURNS VOID
    LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE payment
    SET status = 'CANCELED'
    WHERE payment_id = p_payment_id
      AND status = 'PENDING';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment % is not pending', p_payment_id;
    END IF;
END;
$$;


CREATE FUNCTION refund_payment(p_payment_id INT, p_amount NUMERIC) RETURNS VOID
    LANGUAGE plpgsql AS
$$
DECLARE
    v_payment payment%ROWTYPE;
BEGIN
    SELECT * INTO v_payment FROM payment WHERE payment_id = p_payment_id FOR UPDATE;
    IF v_payment.status IS DISTINCT FROM 'SUCCEEDED' THEN
        RAISE EXCEPTION 'Payment % is not succeeded', p_payment_id;
    END IF;
    IF p_amount <= 0 OR p_amount > v_payment.amount THEN
        RAISE EXCEPTION 'Refund amount must be between 0 and %', v_payment.amount;
    END IF;

    UPDATE booking b
    SET status       = 'CANCELLED',
        cancelled_at = now()
    FROM training t
    WHERE b.subscription_id = v_payment.subscription_id
      AND b.status = 'BOOKED'
      AND t.training_id = b.training_id
      AND t.starts_at > now();

    UPDATE payment
    SET status          = 'REFUNDED',
        refunded_amount = p_amount,
        refunded_at     = now()
    WHERE payment_id = p_payment_id;

    UPDATE subscription
    SET status = 'REFUNDED'
    WHERE subscription_id = v_payment.subscription_id;
END;
$$;


CREATE FUNCTION grant_subscription(p_admin_id INT, p_user_id INT, p_tariff_id INT) RETURNS INT
    LANGUAGE plpgsql AS
$$
DECLARE
    v_tariff          tariff%ROWTYPE;
    v_subscription_id INT;
BEGIN
    SELECT * INTO v_tariff FROM tariff WHERE tariff_id = p_tariff_id;
    IF v_tariff.tariff_id IS NULL THEN
        RAISE EXCEPTION 'Tariff % not found', p_tariff_id;
    END IF;

    INSERT INTO subscription (issued_by, tariff_id, user_id, expires_at, visits_left, status)
    VALUES (p_admin_id, p_tariff_id, p_user_id,
            now() + make_interval(days => v_tariff.duration_days),
            v_tariff.visits_count, 'ACTIVE')
    RETURNING subscription_id INTO v_subscription_id;

    RETURN v_subscription_id;
END;
$$;


CREATE FUNCTION create_training(
    p_lead_id       INT,
    p_place_id      INT,
    p_name          VARCHAR,
    p_starts_at     TIMESTAMPTZ,
    p_duration      INT,
    p_capacity      INT,
    p_playlist      VARCHAR DEFAULT NULL,
    p_assistant_ids INT[] DEFAULT '{}'
) RETURNS INT
    LANGUAGE plpgsql AS
$$
DECLARE
    v_training_id INT;
BEGIN
    IF p_starts_at <= now() THEN
        RAISE EXCEPTION 'Training must start in the future';
    END IF;

    INSERT INTO training (place_id, name, starts_at, capacity, duration, playlist)
    VALUES (p_place_id, p_name, p_starts_at, p_capacity, p_duration, p_playlist)
    RETURNING training_id INTO v_training_id;

    INSERT INTO training_trainer (training_id, trainer_id, role)
    VALUES (v_training_id, p_lead_id, 'LEAD');

    INSERT INTO training_trainer (training_id, trainer_id, role)
    SELECT v_training_id, a.id, 'ASSISTANT'
    FROM unnest(p_assistant_ids) AS a(id)
    WHERE a.id <> p_lead_id;

    RETURN v_training_id;
END;
$$;


CREATE FUNCTION check_training_lead(p_training_id INT, p_trainer_id INT) RETURNS VOID
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1
                   FROM training_trainer
                   WHERE training_id = p_training_id
                     AND trainer_id = p_trainer_id
                     AND role = 'LEAD') THEN
        RAISE EXCEPTION 'Trainer % is not the lead of training %', p_trainer_id, p_training_id;
    END IF;
END;
$$;


CREATE FUNCTION update_training(
    p_training_id INT,
    p_trainer_id  INT,
    p_place_id    INT DEFAULT NULL,
    p_name        VARCHAR DEFAULT NULL,
    p_starts_at   TIMESTAMPTZ DEFAULT NULL,
    p_duration    INT DEFAULT NULL,
    p_capacity    INT DEFAULT NULL,
    p_playlist    VARCHAR DEFAULT NULL
) RETURNS VOID
    LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM check_training_lead(p_training_id, p_trainer_id);

    IF (SELECT starts_at FROM training WHERE training_id = p_training_id) <= now() THEN
        RAISE EXCEPTION 'Training has already started';
    END IF;
    IF p_starts_at <= now() THEN
        RAISE EXCEPTION 'Training must start in the future';
    END IF;

    UPDATE training
    SET place_id  = coalesce(p_place_id, place_id),
        name      = coalesce(p_name, name),
        starts_at = coalesce(p_starts_at, starts_at),
        duration  = coalesce(p_duration, duration),
        capacity  = coalesce(p_capacity, capacity),
        playlist  = coalesce(p_playlist, playlist)
    WHERE training_id = p_training_id;
END;
$$;


CREATE FUNCTION cancel_training(p_training_id INT, p_trainer_id INT) RETURNS INT
    LANGUAGE plpgsql AS
$$
DECLARE
    v_cancelled INT;
BEGIN
    PERFORM check_training_lead(p_training_id, p_trainer_id);

    SELECT count(*)
    INTO v_cancelled
    FROM booking
    WHERE training_id = p_training_id
      AND status = 'BOOKED';

    UPDATE training
    SET status = 'CANCELLED'
    WHERE training_id = p_training_id
      AND status = 'ACTIVE'
      AND starts_at > now();

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Training % cannot be cancelled', p_training_id;
    END IF;

    RETURN v_cancelled;
END;
$$;


CREATE FUNCTION mark_attendance(p_booking_id INT, p_marked_by INT, p_attended BOOLEAN) RETURNS VOID
    LANGUAGE plpgsql AS
$$
DECLARE
    v_training_id INT;
BEGIN
    SELECT training_id INTO v_training_id FROM booking WHERE booking_id = p_booking_id;

    IF NOT EXISTS (SELECT 1 FROM training_trainer WHERE training_id = v_training_id AND trainer_id = p_marked_by)
        AND NOT EXISTS (SELECT 1 FROM app_user WHERE user_id = p_marked_by AND is_admin) THEN
        RAISE EXCEPTION 'User % cannot mark attendance on training %', p_marked_by, v_training_id;
    END IF;

    IF (SELECT starts_at FROM training WHERE training_id = v_training_id) > now() THEN
        RAISE EXCEPTION 'Training has not started yet';
    END IF;

    UPDATE booking
    SET status = CASE WHEN p_attended THEN 'ATTENDED' ELSE 'SKIPPED' END::booking_status
    WHERE booking_id = p_booking_id;
END;
$$;


CREATE FUNCTION save_feedback(p_user_id INT, p_trainer_id INT, p_rating INT, p_description TEXT) RETURNS INT
    LANGUAGE plpgsql AS
$$
DECLARE
    v_feedback_id INT;
BEGIN
    INSERT INTO feedback (user_id, trainer_id, rating, description)
    VALUES (p_user_id, p_trainer_id, p_rating, p_description)
    ON CONFLICT (user_id, trainer_id) DO UPDATE
        SET rating      = excluded.rating,
            description = excluded.description,
            created_at  = now()
    RETURNING feedback_id INTO v_feedback_id;

    RETURN v_feedback_id;
END;
$$;


CREATE PROCEDURE expire_subscriptions()
    LANGUAGE sql AS
$$
UPDATE subscription
SET status = 'EXPIRED'
WHERE status = 'ACTIVE'
  AND expires_at < now();
$$;


CREATE VIEW training_load AS
SELECT t.training_id,
       t.name,
       t.starts_at,
       p.name                                                     AS place_name,
       t.capacity,
       count(b.booking_id) FILTER (WHERE b.status <> 'CANCELLED') AS booked,
       count(b.booking_id) FILTER (WHERE b.status = 'ATTENDED')   AS attended,
       round(100.0 * count(b.booking_id) FILTER (WHERE b.status <> 'CANCELLED') / t.capacity, 1) AS load_percent
FROM training t
         JOIN place p ON p.place_id = t.place_id
         LEFT JOIN booking b ON b.training_id = t.training_id
WHERE t.status = 'ACTIVE'
GROUP BY t.training_id, p.name;


CREATE VIEW trainer_rating AS
SELECT tr.user_id                    AS trainer_id,
       u.first_name,
       round(avg(f.rating), 2)       AS avg_rating,
       count(f.feedback_id)          AS feedback_count
FROM trainer tr
         JOIN app_user u ON u.user_id = tr.user_id
         LEFT JOIN feedback f ON f.trainer_id = tr.user_id
GROUP BY tr.user_id, u.first_name;


CREATE VIEW revenue_by_month AS
SELECT date_trunc('month', p.paid_at)                       AS month,
       t.tariff_id,
       t.name                                               AS tariff_name,
       count(*)                                             AS payments,
       sum(p.amount - coalesce(p.refunded_amount, 0))       AS revenue
FROM payment p
         JOIN subscription s ON s.subscription_id = p.subscription_id
         JOIN tariff t ON t.tariff_id = s.tariff_id
WHERE p.status IN ('SUCCEEDED', 'REFUNDED')
GROUP BY date_trunc('month', p.paid_at), t.tariff_id, t.name;
