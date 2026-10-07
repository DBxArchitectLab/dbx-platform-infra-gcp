output "dns_records" {
  value = { for k, v in google_dns_record_set.this : v.name => v.rrdatas[0] }
}
