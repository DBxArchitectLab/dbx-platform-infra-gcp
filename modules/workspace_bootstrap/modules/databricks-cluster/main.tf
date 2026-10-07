data "databricks_cluster_policy" "existing" {
  for_each = {
    for k, v in var.clusters :
    k => v
    if try(v.policy_name, null) != null && !contains(keys(var.cluster_policy_ids), v.policy_name)
  }

  name = each.value.policy_name
}

data "databricks_spark_version" "latest_lts" {
  latest            = true
  long_term_support = true
}

resource "databricks_cluster" "this" {
  for_each = var.clusters

  cluster_name = each.key

  policy_id = try(
    var.cluster_policy_ids[each.value.policy_name],
    data.databricks_cluster_policy.existing[each.key].id,
    null
  )

  apply_policy_default_values = try(each.value.policy_name, null) != null

  spark_version = coalesce(
    try(each.value.spark_version, null),
    data.databricks_spark_version.latest_lts.id
  )

  node_type_id            = try(each.value.node_type_id, null)
  driver_node_type_id     = try(each.value.driver_node_type_id, null)
  autotermination_minutes = try(each.value.autotermination_minutes, null)
  num_workers             = try(each.value.num_workers, null)
  data_security_mode      = try(each.value.data_security_mode, null)
  runtime_engine          = try(each.value.runtime_engine, null)
  single_user_name        = try(each.value.single_user_name, null)

  spark_conf  = try(each.value.spark_conf, null)
  custom_tags = merge(var.default_tags, try(each.value.custom_tags, {}))

  dynamic "autoscale" {
    for_each = try(each.value.autoscale, null) != null ? [each.value.autoscale] : []
    content {
      min_workers = autoscale.value.min_workers
      max_workers = autoscale.value.max_workers
    }
  }

  dynamic "gcp_attributes" {
    for_each = try(each.value.gcp_attributes, null) != null ? [each.value.gcp_attributes] : []
    content {
      availability           = try(gcp_attributes.value.availability, null)
      first_on_demand        = try(gcp_attributes.value.first_on_demand, null)
      zone_id                = try(gcp_attributes.value.zone_id, null)
      boot_disk_size         = try(gcp_attributes.value.boot_disk_size, null)
      local_ssd_count        = try(gcp_attributes.value.local_ssd_count, null)
      google_service_account = try(gcp_attributes.value.google_service_account, null)
    }
  }

  lifecycle {
    precondition {
      condition = !(
        try(each.value.num_workers, null) != null &&
        try(each.value.autoscale, null) != null
      )
      error_message = "Cluster '${each.key}' cannot define both num_workers and autoscale."
    }

    precondition {
      condition = !(
        try(each.value.data_security_mode, null) == "SINGLE_USER" &&
        try(each.value.single_user_name, null) == null
      )
      error_message = "Cluster '${each.key}' with SINGLE_USER must define single_user_name."
    }

    precondition {
      condition     = try(each.value.policy_name, null) != null
      error_message = "Cluster '${each.key}' must specify policy_name."
    }
  }
}