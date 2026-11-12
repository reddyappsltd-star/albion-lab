terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # State lives in the storage account created by the bootstrap commands.
  backend "azurerm" {
    resource_group_name  = "rg-albion-lab"
    storage_account_name = "sttfalbionrdy47"
    container_name       = "tfstate"
    key                  = "datafactory.tfstate"
  }
}

provider "azurerm" {
  features {}

  # The pipeline identity only has rights on one resource group,
  # so it cannot register resource providers for the subscription.
  resource_provider_registrations = "none"
}

variable "name_suffix" {
  description = "Short unique suffix, lowercase letters and digits only, e.g. your initials and two digits."
  type        = string
}

data "azurerm_resource_group" "lab" {
  name = "rg-albion-lab"
}

resource "azurerm_data_factory" "this" {
  name                = "adf-albion-${var.name_suffix}"
  location            = data.azurerm_resource_group.lab.location
  resource_group_name = data.azurerm_resource_group.lab.name

  # The factory's own identity. Later parts use it instead of stored passwords.
  identity {
    type = "SystemAssigned"
  }

  tags = {
    project = "albion-lab"
  }
}

resource "azurerm_storage_account" "lake" {
  name                            = "stalbion${var.name_suffix}"
  location                        = data.azurerm_resource_group.lab.location
  resource_group_name             = data.azurerm_resource_group.lab.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = {
    project = "albion-lab"
  }
}

resource "azurerm_storage_container" "landing" {
  name               = "landing"
  storage_account_id = azurerm_storage_account.lake.id
}

output "data_factory_name" {
  value = azurerm_data_factory.this.name
}

output "data_factory_principal_id" {
  value = azurerm_data_factory.this.identity[0].principal_id
}