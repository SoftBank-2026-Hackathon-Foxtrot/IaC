output "network_id" {
  value = google_compute_network.this.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.app.id
}

output "service_range_name" {
  value = google_compute_global_address.services.name
}
