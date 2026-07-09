# Authentication and Authorization Rules

- Planned implementation: `src/auth/api_key.ml`, `jwt_session.ml`, `permission_matrix.ml`; request context: `src/shared/tenant_context.ml`.
- `X-API-Key` values are shown only once, stored only as hashes, compared safely, and prefixed by `API_KEY_PREFIX`.
- JWTs include `tenant_id`, `user_id`, and `role`, use `SECRET_KEY_BASE`, expire per `AUTH_TOKEN_TTL_MINUTES`, and refresh only through `POST /api/auth/refresh`.
- Every protected Dream route invokes tenant resolution and `require_permission` before loading route IDs. Unknown permissions fail closed.
- Roles are exactly `tenant_admin`, `auction_manager`, `procurement_analyst`, and `carrier_viewer`; PRD §2b is the authority for allowed actions.
- Carrier viewers require a non-null matching `carrier_id` and see only own bids/generalized explanations.
- Inactive tenant/user is denied. Missing/invalid credential is 401; authenticated insufficient permission is 403; cross-tenant object IDs do not disclose existence.
- Background jobs carry one `tenant_id` and system actor; callbacks authenticate endpoint HMAC/token before tenant lookup.
- `SELF_REGISTRATION_ENABLED=false` makes registration unavailable. Registration and API-key rotation are rate-limited and audited.
- Tests cover every P1/P2/P3 allowed matrix cell when its phase lands, explicit denied cells, token expiry/refresh, inactive principals, two-tenant collisions, and carrier scope.
- Never log credentials, hashes, JWTs, cookies, signatures, password hashes, or full authorization headers.
