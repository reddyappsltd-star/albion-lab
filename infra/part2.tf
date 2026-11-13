# Part 2: a pipeline that copies one file from Amazon S3 into the data lake.

variable "aws_bucket_name" {
  description = "Name of the S3 bucket that holds the source file."
  type        = string
}

variable "aws_access_key_id" {
  description = "Access key ID of the read-only AWS user. An identifier, not the secret."
  type        = string
}

data "azurerm_client_config" "current" {}

# A vault for the one secret this part needs: the AWS secret access key.
resource "azurerm_key_vault" "this" {
  name                       = "kv-albion-${var.name_suffix}"
  location                   = data.azurerm_resource_group.lab.location
  resource_group_name        = data.azurerm_resource_group.lab.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = {
    project = "albion-lab"
  }
}

# Access for the factory's own identity. No passwords involved.
resource "azurerm_role_assignment" "factory_reads_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "factory_writes_lake" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

# Linked services: the factory's saved connections.
resource "azurerm_data_factory_linked_service_key_vault" "vault" {
  name            = "ls_keyvault"
  data_factory_id = azurerm_data_factory.this.id
  key_vault_id    = azurerm_key_vault.this.id
}

resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "lake" {
  name                 = "ls_lake"
  data_factory_id      = azurerm_data_factory.this.id
  url                  = azurerm_storage_account.lake.primary_dfs_endpoint
  use_managed_identity = true
}

resource "azurerm_data_factory_linked_custom_service" "s3" {
  name            = "ls_s3"
  data_factory_id = azurerm_data_factory.this.id
  type            = "AmazonS3"

  type_properties_json = jsonencode({
    authenticationType = "AccessKey"
    accessKeyId        = var.aws_access_key_id
    secretAccessKey = {
      type       = "AzureKeyVaultSecret"
      secretName = "aws-secret-access-key"
      store = {
        referenceName = azurerm_data_factory_linked_service_key_vault.vault.name
        type          = "LinkedServiceReference"
      }
    }
  })
}

# Datasets: where the file is read from and written to.
resource "azurerm_data_factory_custom_dataset" "s3_sales" {
  name            = "ds_s3_sales"
  data_factory_id = azurerm_data_factory.this.id
  type            = "Binary"

  linked_service {
    name = azurerm_data_factory_linked_custom_service.s3.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AmazonS3Location"
      bucketName = var.aws_bucket_name
      folderPath = "incoming"
      fileName   = "sales.csv"
    }
  })
}

resource "azurerm_data_factory_custom_dataset" "lake_sales" {
  name            = "ds_lake_sales"
  data_factory_id = azurerm_data_factory.this.id
  type            = "Binary"

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = azurerm_storage_container.landing.name
      folderPath = "sales"
    }
  })
}

# The Data Factory pipeline: one copy step.
resource "azurerm_data_factory_pipeline" "copy_sales" {
  name            = "pl_copy_sales_from_s3"
  data_factory_id = azurerm_data_factory.this.id

  activities_json = jsonencode([
    {
      name = "CopySalesFile"
      type = "Copy"
      inputs = [
        { referenceName = azurerm_data_factory_custom_dataset.s3_sales.name, type = "DatasetReference" }
      ]
      outputs = [
        { referenceName = azurerm_data_factory_custom_dataset.lake_sales.name, type = "DatasetReference" }
      ]
      typeProperties = {
        source = {
          type          = "BinarySource"
          storeSettings = { type = "AmazonS3ReadSettings", recursive = false }
        }
        sink = {
          type          = "BinarySink"
          storeSettings = { type = "AzureBlobFSWriteSettings" }
        }
      }
    }
  ])
}
