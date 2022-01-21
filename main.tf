/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  bucket = (
    var.bucket_name != null
    ? var.bucket_name
    : (
      length(google_storage_bucket.bucket) > 0
      ? google_storage_bucket.bucket[0].name
      : null
    )
  )
  prefix = var.prefix == null ? "" : "${var.prefix}-"
  service_account_email = (
    var.service_account_create
    ? (
      length(google_service_account.service_account) > 0
      ? google_service_account.service_account[0].email
      : null
    )
    : var.service_account
  )
  vpc_connector = (
    var.vpc_connector == null
    ? null
    : (
      try(var.vpc_connector.create, false) == false
      ? var.vpc_connector.name
      : google_vpc_access_connector.connector.0.id
    )
  )
  special_regions = {
    "europe-west" = "europe-west1"
    "us-central"  = "us-central1"
  }
  sanitized_region         = lookup(local.special_regions, var.region, var.region)
  create_scheduled_trigger = var.trigger_config == null && var.schedule != null
}

resource "google_vpc_access_connector" "connector" {
  count         = try(var.vpc_connector.create, false) == false ? 0 : 1
  project       = var.project_id
  name          = var.vpc_connector.name
  region        = local.sanitized_region
  ip_cidr_range = var.vpc_connector_config.ip_cidr_range
  network       = var.vpc_connector_config.network
}

resource "google_pubsub_topic" "topic" {
  count = local.create_scheduled_trigger ? 1 : 0
  name  = "${local.prefix}${var.name}-topic"
}

resource "google_cloud_scheduler_job" "trigger" {
  count       = local.create_scheduled_trigger ? 1 : 0
  name        = "${local.prefix}${var.name}-trigger"
  description = "Cloud function trigger"
  schedule    = var.schedule
  region      = local.sanitized_region

  pubsub_target {
    topic_name = google_pubsub_topic.topic[0].id
    data       = base64encode("Hit it!")
  }
}

resource "google_cloudfunctions_function" "function" {
  project               = var.project_id
  region                = local.sanitized_region
  name                  = "${local.prefix}${var.name}"
  description           = var.description
  runtime               = var.function_config.runtime
  available_memory_mb   = var.function_config.memory
  max_instances         = var.function_config.instances
  timeout               = var.function_config.timeout
  entry_point           = var.function_config.entry_point
  environment_variables = sensitive(var.environment_variables)
  service_account_email = local.service_account_email
  source_archive_bucket = local.bucket
  source_archive_object = var.source_repository == null ? google_storage_bucket_object.bundle[0].name : null
  labels                = var.labels
  trigger_http          = var.schedule == null ? true : null
  ingress_settings      = var.ingress_settings

  dynamic "source_repository" {
    for_each = var.source_repository == null ? [] : [""]
    content {
      url = var.source_repository
    }
  }

  vpc_connector = local.vpc_connector
  vpc_connector_egress_settings = try(
    var.vpc_connector.egress_settings, null
  )

  dynamic "event_trigger" {
    # Create a trigger from given input if trigger_config is provided
    for_each = local.create_scheduled_trigger ? [] : [""]
    content {
      event_type = var.trigger_config.event
      resource   = var.trigger_config.resource
      dynamic "failure_policy" {
        for_each = var.trigger_config.retry == null ? [] : [""]
        content {
          retry = var.trigger_config.retry
        }
      }
    }
  }

  # Schedule trigger
  dynamic "event_trigger" {
    # Create a schedule trigger if trigger_config isn't provided and schedule is provided
    for_each = local.create_scheduled_trigger ? [""] : []
    content {
      event_type = "google.pubsub.topic.publish"
      resource   = google_pubsub_topic.topic[0].id
      failure_policy {
        retry = var.pubsub_trigger_retry
      }
    }
  }
}

resource "google_cloudfunctions_function_iam_binding" "default" {
  for_each       = var.iam
  project        = var.project_id
  region         = local.sanitized_region
  cloud_function = google_cloudfunctions_function.function.name
  role           = each.key
  members        = each.value
}

resource "google_storage_bucket" "bucket" {
  count   = var.bucket_config == null ? 0 : 1
  project = var.project_id
  name    = "${local.prefix}${var.bucket_name}"
  location = (
    var.bucket_config.location == null
    ? local.sanitized_region
    : var.bucket_config.location
  )
  labels = var.labels

  dynamic "lifecycle_rule" {
    for_each = var.bucket_config.lifecycle_delete_age == null ? [] : [""]
    content {
      action { type = "Delete" }
      condition { age = var.bucket_config.lifecycle_delete_age }
    }
  }
}

resource "google_storage_bucket_object" "bundle" {
  count  = var.source_repository == null ? 1 : 0
  name   = "bundle-${data.archive_file.bundle[0].output_md5}.zip"
  bucket = local.bucket
  source = data.archive_file.bundle[0].output_path
}

data "archive_file" "bundle" {
  count      = var.source_repository == null ? 1 : 0
  type       = "zip"
  source_dir = var.bundle_config.source_dir
  output_path = (
    var.bundle_config.output_path == null
    ? "/tmp/bundle.zip"
    : var.bundle_config.output_path
  )
  output_file_mode = "0666"
  excludes         = var.bundle_config.excludes
}

resource "google_service_account" "service_account" {
  count        = var.service_account_create ? 1 : 0
  project      = var.project_id
  account_id   = "tf-cf-${var.name}"
  display_name = "Terraform Cloud Function ${var.name}."
}
