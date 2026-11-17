CREATE TYPE payment_status AS ENUM ('PENDING', 'SUCCEEDED', 'CANCELED', 'REFUNDED');
CREATE TYPE payment_method_type AS ENUM ('BANK_CARD', 'SBP', 'SBERBANK');
CREATE TYPE subscription_status AS ENUM ('PENDING', 'ACTIVE', 'EXPIRED', 'USED_UP', 'REFUNDED', 'CANCELED');
CREATE TYPE tariff_type AS ENUM ('SINGLE', 'PACK', 'PERIOD');
CREATE TYPE document_type AS ENUM ('STUDIO_RULES', 'PRIVACY', 'OFFER');
CREATE TYPE booking_status AS ENUM ('BOOKED', 'ATTENDED', 'SKIPPED', 'CANCELLED');
CREATE TYPE training_status AS ENUM ('ACTIVE', 'CANCELLED');
CREATE TYPE trainer_role AS ENUM ('LEAD', 'ASSISTANT');

CREATE TABLE app_user (
    user_id          SERIAL PRIMARY KEY,
    first_name       VARCHAR(50)  NOT NULL,
    phone_number     VARCHAR(20)  UNIQUE,
    email            VARCHAR(100) UNIQUE,
    password_hash    VARCHAR(60),
    vk_id            BIGINT       UNIQUE,
    google_id        VARCHAR(50)  UNIQUE,
    referral_link_id INT,
    is_admin         BOOLEAN      NOT NULL DEFAULT FALSE,
    avatar_path      VARCHAR(255),
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT app_user_login_chk
        CHECK (phone_number IS NOT NULL OR email IS NOT NULL OR vk_id IS NOT NULL OR google_id IS NOT NULL),
    CONSTRAINT app_user_password_chk
        CHECK (password_hash IS NULL OR phone_number IS NOT NULL OR email IS NOT NULL)
);

CREATE TABLE referral_link (
    referral_link_id SERIAL PRIMARY KEY,
    user_id          INT         NOT NULL UNIQUE REFERENCES app_user (user_id) ON DELETE CASCADE,
    code             VARCHAR(16) NOT NULL UNIQUE,
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE app_user
    ADD CONSTRAINT app_user_referral_link_fk
        FOREIGN KEY (referral_link_id) REFERENCES referral_link (referral_link_id) ON DELETE SET NULL;

CREATE TABLE document (
    document_id SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    file_path   VARCHAR(255) NOT NULL,
    version     INT,
    type        document_type,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT document_version_chk CHECK (version > 0)
);

CREATE TABLE user_consent (
    document_id INT         NOT NULL REFERENCES document (document_id),
    user_id     INT         NOT NULL REFERENCES app_user (user_id) ON DELETE CASCADE,
    accepted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, user_id)
);

CREATE TABLE trainer (
    user_id     INT     PRIMARY KEY REFERENCES app_user (user_id),
    description TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE trainer_photo (
    photo_id   SERIAL PRIMARY KEY,
    trainer_id INT          NOT NULL REFERENCES trainer (user_id) ON DELETE CASCADE,
    photo_path VARCHAR(255) NOT NULL,
    sort_order INT          NOT NULL,
    CONSTRAINT trainer_photo_sort_order_chk CHECK (sort_order >= 0)
);

CREATE TABLE feedback (
    feedback_id SERIAL PRIMARY KEY,
    user_id     INT         NOT NULL REFERENCES app_user (user_id),
    trainer_id  INT         NOT NULL REFERENCES trainer (user_id),
    rating      INT         NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT feedback_user_trainer_uk UNIQUE (user_id, trainer_id),
    CONSTRAINT feedback_rating_chk CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT feedback_not_self_chk CHECK (user_id <> trainer_id)
);

CREATE TABLE place (
    place_id    SERIAL PRIMARY KEY,
    name        VARCHAR(50)  NOT NULL UNIQUE,
    description TEXT,
    photo_path  VARCHAR(255),
    address     VARCHAR(150) NOT NULL,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    capacity    INT          NOT NULL,
    CONSTRAINT place_capacity_chk CHECK (capacity > 0)
);

CREATE TABLE training (
    training_id SERIAL PRIMARY KEY,
    place_id    INT             NOT NULL REFERENCES place (place_id),
    name        VARCHAR(50)     NOT NULL,
    starts_at   TIMESTAMPTZ     NOT NULL,
    capacity    INT             NOT NULL,
    duration    INT             NOT NULL,
    status      training_status NOT NULL DEFAULT 'ACTIVE',
    playlist    VARCHAR(255),
    CONSTRAINT training_capacity_chk CHECK (capacity > 0),
    CONSTRAINT training_duration_chk CHECK (duration > 0)
);

CREATE TABLE training_trainer (
    training_id INT          NOT NULL REFERENCES training (training_id) ON DELETE CASCADE,
    trainer_id  INT          NOT NULL REFERENCES trainer (user_id),
    role        trainer_role NOT NULL,
    PRIMARY KEY (training_id, trainer_id)
);

CREATE UNIQUE INDEX training_trainer_one_lead_uk
    ON training_trainer (training_id) WHERE role = 'LEAD';

CREATE TABLE tariff (
    tariff_id     SERIAL PRIMARY KEY,
    name          VARCHAR(50)    NOT NULL UNIQUE,
    type          tariff_type    NOT NULL,
    price         NUMERIC(10, 2) NOT NULL,
    visits_count  INT,
    duration_days INT,
    is_active     BOOLEAN        NOT NULL DEFAULT TRUE,
    description   TEXT,
    CONSTRAINT tariff_price_chk CHECK (price >= 0),
    CONSTRAINT tariff_duration_chk CHECK (duration_days > 0),
    CONSTRAINT tariff_type_chk CHECK (
        (type = 'SINGLE' AND visits_count = 1)
        OR (type = 'PACK' AND visits_count > 0)
        OR (type = 'PERIOD' AND visits_count IS NULL AND duration_days IS NOT NULL)
    )
);

CREATE TABLE subscription (
    subscription_id SERIAL PRIMARY KEY,
    issued_by       INT                 REFERENCES app_user (user_id),
    tariff_id       INT                 NOT NULL REFERENCES tariff (tariff_id),
    user_id         INT                 NOT NULL REFERENCES app_user (user_id),
    expires_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),
    visits_left     INT,
    status          subscription_status NOT NULL DEFAULT 'PENDING',
    CONSTRAINT subscription_visits_left_chk CHECK (visits_left >= 0)
);

CREATE TABLE payment_method (
    payment_method_id  SERIAL PRIMARY KEY,
    user_id            INT                 NOT NULL REFERENCES app_user (user_id),
    provider_method_id VARCHAR(50)         NOT NULL UNIQUE,
    type               payment_method_type NOT NULL,
    title              VARCHAR(100)        NOT NULL,
    is_active          BOOLEAN             NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ         NOT NULL DEFAULT now()
);

CREATE TABLE payment (
    payment_id          SERIAL PRIMARY KEY,
    subscription_id     INT            NOT NULL REFERENCES subscription (subscription_id),
    payment_method_id   INT            REFERENCES payment_method (payment_method_id),
    amount              NUMERIC(10, 2) NOT NULL,
    status              payment_status NOT NULL DEFAULT 'PENDING',
    provider_payment_id VARCHAR(50)    UNIQUE,
    idempotence_key     UUID           NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT now(),
    paid_at             TIMESTAMPTZ,
    refunded_amount     NUMERIC(10, 2),
    refunded_at         TIMESTAMPTZ,
    CONSTRAINT payment_amount_chk CHECK (amount > 0),
    CONSTRAINT payment_paid_at_chk CHECK ((status IN ('SUCCEEDED', 'REFUNDED')) = (paid_at IS NOT NULL)),
    CONSTRAINT payment_refunded_at_chk CHECK ((status = 'REFUNDED') = (refunded_at IS NOT NULL)),
    CONSTRAINT payment_refunded_amount_chk CHECK ((status = 'REFUNDED') = (refunded_amount IS NOT NULL)),
    CONSTRAINT payment_refunded_range_chk CHECK (refunded_amount BETWEEN 0 AND amount)
);

CREATE UNIQUE INDEX payment_one_pending_uk
    ON payment (subscription_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX payment_one_paid_uk
    ON payment (subscription_id) WHERE status IN ('SUCCEEDED', 'REFUNDED');

CREATE TABLE booking (
    booking_id      SERIAL PRIMARY KEY,
    user_id         INT            NOT NULL REFERENCES app_user (user_id),
    training_id     INT            NOT NULL REFERENCES training (training_id),
    subscription_id INT            NOT NULL REFERENCES subscription (subscription_id),
    status          booking_status NOT NULL DEFAULT 'BOOKED',
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),
    cancelled_at    TIMESTAMPTZ,
    CONSTRAINT booking_cancelled_at_chk CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL))
);

CREATE UNIQUE INDEX booking_user_training_uk
    ON booking (user_id, training_id) WHERE status <> 'CANCELLED';
