SELECT d.id, h.id AS household_id, h.name FROM millitop_tv.devices d JOIN millitop_tv.households h ON h.id=d.household_id WHERE d.revoked_at IS NULL LIMIT 3;
