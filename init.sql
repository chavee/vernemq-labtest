CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS vmq_auth_acl (
    mountpoint VARCHAR(10) NOT NULL,
    client_id VARCHAR(128) NOT NULL,
    username VARCHAR(128) NOT NULL,
    password VARCHAR(128),
    publish_acl JSON,
    subscribe_acl JSON,
    PRIMARY KEY (mountpoint, client_id, username)
);

-- We use client_id = '*' which means it matches ANY client_id for this username
INSERT INTO vmq_auth_acl (mountpoint, client_id, username, password, publish_acl, subscribe_acl)
VALUES ('', '*', 'test-user', 'test-password', '[{"pattern": "#"}]', '[{"pattern": "#"}]')
ON CONFLICT (mountpoint, client_id, username) DO NOTHING;
