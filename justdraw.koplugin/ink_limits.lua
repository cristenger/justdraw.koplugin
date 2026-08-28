-- Shared safety budgets for one physical stylus contact.
--
-- These are deliberately internal constants, not user preferences. The
-- sequence constructor may override them for tests and instrumented builds,
-- but production hosts should import these exact defaults.
return {
    MAX_OPEN_POINTS = 8192,
    MAX_CONTACT_SAMPLES = 32768,
}
