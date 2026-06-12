# ── Example: add Prometheus as a datasource ──────────────────────────────────
# Rename to prometheus.yml and fill in your Prometheus URL.
#
# apiVersion: 1
#
# datasources:
#   - name: Prometheus
#     type: prometheus
#     access: proxy
#     url: http://prometheus:9090
#     isDefault: true
#     editable: false
#     jsonData:
#       httpMethod: POST
#       timeInterval: "15s"
