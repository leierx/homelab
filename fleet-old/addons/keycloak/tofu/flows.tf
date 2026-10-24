# the realm's browser flow: signed in, then refused without a tier
resource "keycloak_authentication_flow" "browser" {
  realm_id = keycloak_realm.homelab.id
  alias    = "homelab-browser"
}

resource "keycloak_authentication_subflow" "sign_in" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_flow.browser.alias
  alias             = "homelab-browser sign-in"
  requirement       = "REQUIRED"
  priority          = 10
}

resource "keycloak_authentication_subflow" "tier" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_flow.browser.alias
  alias             = "homelab-browser tier"
  requirement       = "CONDITIONAL"
  priority          = 20
}

resource "keycloak_authentication_subflow" "forms" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.sign_in.alias
  alias             = "homelab-browser forms"
  requirement       = "ALTERNATIVE"
  priority          = 20
}

resource "keycloak_authentication_subflow" "second_factor" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.forms.alias
  alias             = "homelab-browser second factor"
  requirement       = "CONDITIONAL"
  priority          = 20
}

resource "keycloak_authentication_subflow" "enrol" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.forms.alias
  alias             = "homelab-browser enrol"
  requirement       = "CONDITIONAL"
  priority          = 30
}

resource "keycloak_authentication_execution" "cookie" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.sign_in.alias
  authenticator     = "auth-cookie"
  requirement       = "ALTERNATIVE"
  priority          = 10
}

resource "keycloak_authentication_execution" "username_password" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.forms.alias
  authenticator     = "auth-username-password-form"
  requirement       = "REQUIRED"
  priority          = 10
}

# whichever second factor the user has set up (Keycloak's "2FA all alternative with OTP default", WebAuthn first)
resource "keycloak_authentication_execution" "configured_second_factor" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.second_factor.alias
  authenticator     = "conditional-user-configured"
  requirement       = "REQUIRED"
  priority          = 10
}

resource "keycloak_authentication_execution" "webauthn" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.second_factor.alias
  authenticator     = "webauthn-authenticator"
  requirement       = "ALTERNATIVE"
  priority          = 20
}

resource "keycloak_authentication_execution" "otp" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.second_factor.alias
  authenticator     = "auth-otp-form"
  requirement       = "ALTERNATIVE"
  priority          = 30
}

resource "keycloak_authentication_execution" "recovery_codes" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.second_factor.alias
  authenticator     = "auth-recovery-authn-code-form"
  requirement       = "ALTERNATIVE"
  priority          = 40
}

# no second factor yet: register a security key or passkey before going on
resource "keycloak_authentication_execution" "no_second_factor" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.enrol.alias
  authenticator     = "conditional-sub-flow-executed"
  requirement       = "REQUIRED"
  priority          = 10
}

resource "keycloak_authentication_execution" "enrol_webauthn" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.enrol.alias
  authenticator     = "webauthn-authenticator"
  requirement       = "REQUIRED"
  priority          = 20
}

resource "keycloak_authentication_execution" "no_tier" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.tier.alias
  authenticator     = "conditional-user-role"
  requirement       = "REQUIRED"
  priority          = 10
}

resource "keycloak_authentication_execution" "deny_without_tier" {
  realm_id          = keycloak_realm.homelab.id
  parent_flow_alias = keycloak_authentication_subflow.tier.alias
  authenticator     = "deny-access-authenticator"
  requirement       = "REQUIRED"
  priority          = 20
}

resource "keycloak_authentication_execution_config" "no_second_factor" {
  realm_id     = keycloak_realm.homelab.id
  execution_id = keycloak_authentication_execution.no_second_factor.id
  alias        = "homelab-no-second-factor"
  config = {
    flow_to_check = keycloak_authentication_subflow.second_factor.alias
    check_result  = "not-executed"
  }
}

resource "keycloak_authentication_execution_config" "no_tier" {
  realm_id     = keycloak_realm.homelab.id
  execution_id = keycloak_authentication_execution.no_tier.id
  alias        = "homelab-no-tier"
  config = {
    condUserRole = keycloak_role.homelab_access.name
    negate       = "true"
  }
}

resource "keycloak_authentication_bindings" "homelab" {
  realm_id     = keycloak_realm.homelab.id
  browser_flow = keycloak_authentication_flow.browser.alias
}
