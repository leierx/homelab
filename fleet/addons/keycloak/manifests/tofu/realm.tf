resource "keycloak_realm" "homelab" {
  realm                  = "homelab"
  enabled                = true
  display_name           = "homelab"
  registration_allowed   = false
  reset_password_allowed = false
  verify_email           = false

  # 12 h, so kubectl's refresh token (client kubernetes) lives that long
  sso_session_idle_timeout = "12h"
  sso_session_max_lifespan = "12h"

  # the name a security key or passkey shows for this site
  web_authn_policy {
    relying_party_entity_name = "homelab"
  }

  # F2: no simple passwords, and the password history stops a quick change back
  password_policy = "length(16) and notUsername(1) and passwordHistory(5)"

  # F3: temporary lockout at ten failures; the strategy is explicit, not inherited
  security_defenses {
    brute_force_detection {
      permanent_lockout                = false
      brute_force_strategy             = "MULTIPLE"
      max_temporary_lockouts           = 0
      max_login_failures               = 10
      max_secondary_auth_failures      = 0
      wait_increment_seconds           = 60
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60
      max_failure_wait_seconds         = 900
      failure_reset_time_seconds       = 43200
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# F5: events and admin events are the audit trail of the realm
resource "keycloak_realm_events" "homelab" {
  realm_id = keycloak_realm.homelab.id

  events_enabled               = true
  admin_events_enabled         = true
  admin_events_details_enabled = false
  # 90 days
  events_expiration = 7776000
  # new realms get jboss-logging by default; this resource would remove it otherwise
  events_listeners = ["jboss-logging"]
}
