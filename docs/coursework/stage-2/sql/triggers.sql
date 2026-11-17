CREATE FUNCTION booking_cancel_window() RETURNS INTERVAL
    LANGUAGE sql IMMUTABLE AS
$$
SELECT INTERVAL '24 hours'
$$;

CREATE FUNCTION training_period(p_starts_at TIMESTAMPTZ, p_duration INT) RETURNS TSTZRANGE
    LANGUAGE sql IMMUTABLE AS
$$
SELECT tstzrange(p_starts_at, p_starts_at + make_interval(mins => p_duration))
$$;


CREATE FUNCTION check_trainer_overlap(p_trainer_id INT, p_training_id INT) RETURNS VOID
    LANGUAGE plpgsql AS
$$
DECLARE
    v_conflict_id INT;
BEGIN
    SELECT t2.training_id
    INTO v_conflict_id
    FROM training t1
             JOIN training_trainer tt2 ON tt2.trainer_id = p_trainer_id AND tt2.training_id <> t1.training_id
             JOIN training t2 ON t2.training_id = tt2.training_id
    WHERE t1.training_id = p_training_id
      AND t1.status = 'ACTIVE'
      AND t2.status = 'ACTIVE'
      AND training_period(t1.starts_at, t1.duration) && training_period(t2.starts_at, t2.duration)
    LIMIT 1;

    IF v_conflict_id IS NOT NULL THEN
        RAISE EXCEPTION 'Trainer % already works on training % at the same time', p_trainer_id, v_conflict_id;
    END IF;
END;
$$;


CREATE FUNCTION trg_training_trainer_check() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM 1 FROM trainer WHERE user_id = NEW.trainer_id FOR UPDATE;

    IF (TG_OP = 'INSERT' OR NEW.trainer_id <> OLD.trainer_id)
        AND NOT (SELECT is_active FROM trainer WHERE user_id = NEW.trainer_id) THEN
        RAISE EXCEPTION 'Trainer % is not active', NEW.trainer_id;
    END IF;

    PERFORM check_trainer_overlap(NEW.trainer_id, NEW.training_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER training_trainer_check
    AFTER INSERT OR UPDATE ON training_trainer
    FOR EACH ROW
EXECUTE FUNCTION trg_training_trainer_check();


CREATE FUNCTION trg_training_lead_required() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_training_id INT;
BEGIN
    IF TG_TABLE_NAME = 'training' THEN
        v_training_id := NEW.training_id;
    ELSE
        v_training_id := OLD.training_id;
    END IF;

    IF EXISTS (SELECT 1 FROM training WHERE training_id = v_training_id)
        AND NOT EXISTS (SELECT 1
                        FROM training_trainer
                        WHERE training_id = v_training_id
                          AND role = 'LEAD') THEN
        RAISE EXCEPTION 'Training % must have a lead trainer', v_training_id;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER training_lead_required
    AFTER INSERT ON training
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE FUNCTION trg_training_lead_required();

CREATE CONSTRAINT TRIGGER training_trainer_lead_required
    AFTER UPDATE OR DELETE ON training_trainer
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE FUNCTION trg_training_lead_required();


CREATE FUNCTION trg_training_check() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_place  place%ROWTYPE;
    v_booked INT;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status = 'CANCELLED' AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'Training % is cancelled and cannot be changed', OLD.training_id;
    END IF;

    SELECT * INTO v_place FROM place WHERE place_id = NEW.place_id;

    IF (TG_OP = 'INSERT' OR NEW.place_id <> OLD.place_id) AND NOT v_place.is_active THEN
        RAISE EXCEPTION 'Place % is closed', NEW.place_id;
    END IF;

    IF NEW.capacity > v_place.capacity THEN
        RAISE EXCEPTION 'Training capacity % exceeds place capacity %', NEW.capacity, v_place.capacity;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.capacity < OLD.capacity THEN
        SELECT count(*)
        INTO v_booked
        FROM booking
        WHERE training_id = NEW.training_id
          AND status <> 'CANCELLED';

        IF NEW.capacity < v_booked THEN
            RAISE EXCEPTION 'Training capacity % is less than number of bookings %', NEW.capacity, v_booked;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER training_check
    BEFORE INSERT OR UPDATE ON training
    FOR EACH ROW
EXECUTE FUNCTION trg_training_check();


CREATE FUNCTION trg_training_after_update() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_trainer_id INT;
BEGIN
    IF NEW.status = 'CANCELLED' AND OLD.status = 'ACTIVE' THEN
        UPDATE booking
        SET status       = 'CANCELLED',
            cancelled_at = now()
        WHERE training_id = NEW.training_id
          AND status = 'BOOKED';
    ELSIF NEW.starts_at <> OLD.starts_at OR NEW.duration <> OLD.duration THEN
        FOR v_trainer_id IN SELECT trainer_id FROM training_trainer WHERE training_id = NEW.training_id
            LOOP
                PERFORM check_trainer_overlap(v_trainer_id, NEW.training_id);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER training_after_update
    AFTER UPDATE ON training
    FOR EACH ROW
EXECUTE FUNCTION trg_training_after_update();


CREATE FUNCTION trg_booking_insert() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_training     training%ROWTYPE;
    v_subscription subscription%ROWTYPE;
    v_booked       INT;
BEGIN
    IF NEW.status <> 'BOOKED' THEN
        RAISE EXCEPTION 'New booking must have status BOOKED';
    END IF;

    SELECT * INTO v_training FROM training WHERE training_id = NEW.training_id FOR UPDATE;
    IF v_training.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Training % is cancelled', NEW.training_id;
    END IF;

    SELECT * INTO v_subscription FROM subscription WHERE subscription_id = NEW.subscription_id FOR UPDATE;
    IF v_subscription.user_id <> NEW.user_id THEN
        RAISE EXCEPTION 'Subscription % does not belong to user %', NEW.subscription_id, NEW.user_id;
    END IF;
    IF v_subscription.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Subscription % is not active', NEW.subscription_id;
    END IF;
    IF v_subscription.expires_at < v_training.starts_at THEN
        RAISE EXCEPTION 'Subscription % expires before training %', NEW.subscription_id, NEW.training_id;
    END IF;

    SELECT count(*)
    INTO v_booked
    FROM booking
    WHERE training_id = NEW.training_id
      AND status <> 'CANCELLED';
    IF v_booked >= v_training.capacity THEN
        RAISE EXCEPTION 'No free seats on training %', NEW.training_id;
    END IF;

    UPDATE subscription
    SET visits_left = visits_left - 1
    WHERE subscription_id = NEW.subscription_id
      AND visits_left IS NOT NULL;

    NEW.cancelled_at := NULL;
    RETURN NEW;
END;
$$;

CREATE TRIGGER booking_insert
    BEFORE INSERT ON booking
    FOR EACH ROW
EXECUTE FUNCTION trg_booking_insert();


CREATE FUNCTION trg_booking_update() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_training training%ROWTYPE;
BEGIN
    IF NEW.user_id <> OLD.user_id
        OR NEW.training_id <> OLD.training_id
        OR NEW.subscription_id <> OLD.subscription_id THEN
        RAISE EXCEPTION 'Booking % cannot be moved to another user, training or subscription', OLD.booking_id;
    END IF;

    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'CANCELLED'
        OR NEW.status = 'BOOKED'
        OR (NEW.status = 'CANCELLED' AND OLD.status <> 'BOOKED') THEN
        RAISE EXCEPTION 'Booking status cannot change from % to %', OLD.status, NEW.status;
    END IF;

    IF NEW.status = 'CANCELLED' THEN
        NEW.cancelled_at := coalesce(NEW.cancelled_at, now());

        SELECT * INTO v_training FROM training WHERE training_id = NEW.training_id;
        IF v_training.status = 'CANCELLED'
            OR NEW.cancelled_at <= v_training.starts_at - booking_cancel_window() THEN
            UPDATE subscription
            SET visits_left = visits_left + 1
            WHERE subscription_id = NEW.subscription_id
              AND visits_left IS NOT NULL;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER booking_update
    BEFORE UPDATE ON booking
    FOR EACH ROW
EXECUTE FUNCTION trg_booking_update();


CREATE FUNCTION trg_subscription_check() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.user_id <> OLD.user_id OR NEW.tariff_id <> OLD.tariff_id) THEN
        RAISE EXCEPTION 'Subscription % cannot change owner or tariff', OLD.subscription_id;
    END IF;

    IF NEW.issued_by IS NOT NULL
        AND (TG_OP = 'INSERT' OR NEW.issued_by IS DISTINCT FROM OLD.issued_by)
        AND NOT (SELECT is_admin FROM app_user WHERE user_id = NEW.issued_by) THEN
        RAISE EXCEPTION 'User % is not an administrator', NEW.issued_by;
    END IF;

    IF NEW.status = 'ACTIVE' AND NEW.visits_left = 0 THEN
        NEW.status := 'USED_UP';
    ELSIF NEW.status = 'USED_UP' AND NEW.visits_left > 0 THEN
        NEW.status := CASE WHEN NEW.expires_at < now() THEN 'EXPIRED' ELSE 'ACTIVE' END;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER subscription_check
    BEFORE INSERT OR UPDATE ON subscription
    FOR EACH ROW
EXECUTE FUNCTION trg_subscription_check();


CREATE FUNCTION trg_payment_check() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_method payment_method%ROWTYPE;
BEGIN
    IF NEW.payment_method_id IS NULL
        OR (TG_OP = 'UPDATE' AND NEW.payment_method_id IS NOT DISTINCT FROM OLD.payment_method_id) THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_method FROM payment_method WHERE payment_method_id = NEW.payment_method_id;
    IF v_method.user_id <> (SELECT user_id FROM subscription WHERE subscription_id = NEW.subscription_id) THEN
        RAISE EXCEPTION 'Payment method % belongs to another user', NEW.payment_method_id;
    END IF;
    IF NOT v_method.is_active THEN
        RAISE EXCEPTION 'Payment method % is deleted', NEW.payment_method_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER payment_check
    BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW
EXECUTE FUNCTION trg_payment_check();


CREATE FUNCTION trg_feedback_check() RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1
                   FROM booking b
                            JOIN training_trainer tt ON tt.training_id = b.training_id
                   WHERE b.user_id = NEW.user_id
                     AND tt.trainer_id = NEW.trainer_id
                     AND b.status = 'ATTENDED') THEN
        RAISE EXCEPTION 'User % has not attended trainings of trainer %', NEW.user_id, NEW.trainer_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER feedback_check
    BEFORE INSERT OR UPDATE OF user_id, trainer_id ON feedback
    FOR EACH ROW
EXECUTE FUNCTION trg_feedback_check();
