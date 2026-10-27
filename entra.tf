# Phase 2, optional: Entra groups and the Dependency-Track app registration.
# Off by default (var.manage_entra) because it needs Microsoft Graph
# permissions most deployment identities don't have; the delivery plan has
# the equivalent manual steps.

locals {
  entra_count = var.manage_entra ? 1 : 0

  # Built from the environment's domain rather than read from
  # azurerm_container_app.dtrack_ui, because the UI's env vars depend on
  # this app's client ID — reading the FQDN back would be a cycle.
  dtrack_ui_url = "https://ca-dtrack-ui.${azurerm_container_app_environment.this.default_domain}"

  entra_groups = var.manage_entra ? merge(
    { "sg-sbom-cps-admins" = "CPS security: sees every org in Dependency-Track and Sentinel" },
    { for org in var.sbom_orgs : "sg-sbom-org-${org}" => "Team for GitHub org ${org}: sees only that org's Dependency-Track projects" },
  ) : {}
}

data "azuread_client_config" "current" {
  count = local.entra_count
}

resource "azuread_group" "sbom" {
  for_each = local.entra_groups

  display_name     = each.key
  description      = each.value
  security_enabled = true
  owners           = [data.azuread_client_config.current[0].object_id]
}

resource "azuread_application" "dtrack" {
  count = local.entra_count

  display_name = "Dependency-Track (sbom-${local.env})"
  owners       = [data.azuread_client_config.current[0].object_id]

  # Emit only groups assigned to this app, as display names — so the
  # groups claim carries "sg-sbom-org-<org>", which is what the OIDC group
  # mappings in Dependency-Track are named after (dtrack_admin.py
  # onboard-org), and the token stays small.
  group_membership_claims = ["ApplicationGroup"]

  optional_claims {
    id_token {
      name                  = "groups"
      additional_properties = ["cloud_displayname"]
    }
    access_token {
      name                  = "groups"
      additional_properties = ["cloud_displayname"]
    }
  }

  # The Dependency-Track frontend is a SPA using the authorization code flow
  # with PKCE; this is its callback page.
  single_page_application {
    redirect_uris = ["${local.dtrack_ui_url}/static/oidc-callback.html"]
  }
}

resource "azuread_service_principal" "dtrack" {
  count = local.entra_count

  client_id = azuread_application.dtrack[0].client_id
  owners    = [data.azuread_client_config.current[0].object_id]

  # Only members of the assigned groups below can sign in at all (N2).
  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "dtrack" {
  for_each = azuread_group.sbom

  app_role_id         = "00000000-0000-0000-0000-000000000000" # default access
  principal_object_id = each.value.object_id
  resource_object_id  = azuread_service_principal.dtrack[0].object_id
}
