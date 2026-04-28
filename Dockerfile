# Stage 2 deploy image for the AgentForge Clinical Co-Pilot project.
# Extends the upstream OpenEMR 7.0.3 image. Build customizations,
# config overrides, and (later) the agent service hooks live here.

FROM openemr/openemr:7.0.3

# Railway sends signals on container shutdown; default is fine.
# OpenEMR's Apache listens on 80 internally; Railway maps it externally.
EXPOSE 80

# Future: COPY agent/ /opt/agent/
# Future: COPY config/site-overrides.conf /etc/apache2/conf.d/