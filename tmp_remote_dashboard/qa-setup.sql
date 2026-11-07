INSERT INTO millitop_tv.devices(id,household_id,name,enrolled_at)
VALUES ('99999999-9999-4999-8999-999999999999','664d46b2-dd0a-41d5-b420-f1875b7d5ad3','QA Smoke Test Device',now())
ON CONFLICT (id) DO NOTHING;
INSERT INTO millitop_tv.device_credentials(device_id,token_hash)
VALUES ('99999999-9999-4999-8999-999999999999', encode(digest('qa-smoke-test-token-0000000000000000000000','sha256'),'hex'))
ON CONFLICT DO NOTHING;
