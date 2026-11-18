# Optional (manage_entra): the Entra groups and Dependency-Track app registration.
locals {
  entra_count = var.manage_entra ? 1 : 0

  # Built from the domain: reading it from the UI app would be a dependency cycle.
  dtrack_ui_url = "https://ca-dtrack-ui.${azurerm_container_app_environment.this.default_domain}"

  # Must match the team names dtrack_admin.py maps them to.
  entra_groups = var.manage_entra ? {
    "sg-sbom-cps-admins" = "CPS: administers Dependency-Track (teams, policies, configuration)"
    "sg-sbom-cps-users"  = "CPS: views and triages findings in Dependency-Track"
  } : {}
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

  # Only the assigned groups, by name, which is what Dependency-Track maps.
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

  single_page_application {
    redirect_uris = ["${local.dtrack_ui_url}/static/oidc-callback.html"]
  }
}

resource "azuread_service_principal" "dtrack" {
  count = local.entra_count

  client_id = azuread_application.dtrack[0].client_id
  owners    = [data.azuread_client_config.current[0].object_id]

  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "dtrack" {
  for_each = azuread_group.sbom

  app_role_id         = "00000000-0000-0000-0000-000000000000" # default access
  principal_object_id = each.value.object_id
  resource_object_id  = azuread_service_principal.dtrack[0].object_id
}
