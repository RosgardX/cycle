DROP VIEW IF EXISTS revenue_by_month, trainer_rating, training_load;

DROP PROCEDURE IF EXISTS expire_subscriptions();
DROP FUNCTION IF EXISTS
    register_user(VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT, VARCHAR, VARCHAR, INT[]),
    get_schedule(TIMESTAMPTZ, TIMESTAMPTZ, INT, INT),
    book_training(INT, INT, INT),
    cancel_booking(INT, INT),
    buy_tariff(INT, INT, INT),
    create_payment(INT, INT),
    confirm_payment(INT, VARCHAR),
    cancel_payment(INT),
    refund_payment(INT, NUMERIC),
    grant_subscription(INT, INT, INT),
    create_training(INT, INT, VARCHAR, TIMESTAMPTZ, INT, INT, VARCHAR, INT[]),
    update_training(INT, INT, INT, VARCHAR, TIMESTAMPTZ, INT, INT, VARCHAR),
    cancel_training(INT, INT),
    check_training_lead(INT, INT),
    mark_attendance(INT, INT, BOOLEAN),
    save_feedback(INT, INT, INT, TEXT);

DROP TABLE IF EXISTS
    booking,
    payment,
    payment_method,
    subscription,
    tariff,
    training_trainer,
    training,
    place,
    feedback,
    trainer_photo,
    trainer,
    user_consent,
    document,
    referral_link,
    app_user
    CASCADE;

DROP FUNCTION IF EXISTS
    trg_training_trainer_check(),
    trg_training_lead_required(),
    trg_training_check(),
    trg_training_after_update(),
    trg_booking_insert(),
    trg_booking_update(),
    trg_subscription_check(),
    trg_payment_check(),
    trg_feedback_check(),
    check_trainer_overlap(INT, INT),
    training_period(TIMESTAMPTZ, INT),
    booking_cancel_window();

DROP TYPE IF EXISTS
    payment_status,
    payment_method_type,
    subscription_status,
    tariff_type,
    document_type,
    booking_status,
    training_status,
    trainer_role;
