CREATE INDEX training_starts_at_idx ON training (starts_at) WHERE status = 'ACTIVE';
CREATE INDEX training_period_idx ON training USING gist (training_period(starts_at, duration)) WHERE status = 'ACTIVE';
CREATE INDEX booking_training_idx ON booking (training_id) WHERE status <> 'CANCELLED';
CREATE INDEX subscription_user_idx ON subscription (user_id);
