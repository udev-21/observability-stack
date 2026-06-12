# ── Example: auto-load dashboards from a folder ──────────────────────────────
# Rename to dashboards.yml and place your *.json dashboard files in ./files/.
#
# apiVersion: 1
#
# providers:
#   - name: default
#     orgId: 1
#     type: file
#     disableDeletion: false
#     updateIntervalSeconds: 60
#     allowUiUpdates: true
#     options:
#       path: /etc/grafana/provisioning/dashboards/files
#       foldersFromFilesStructure: true
