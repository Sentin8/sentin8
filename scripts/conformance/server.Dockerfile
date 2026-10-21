# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Sentin8
# SPDX-License-Identifier: Apache-2.0

# Derived OIDF conformance-suite server image (DESIGN §9a.2).
#
# The suite's Java client calls the Sentin8 OP over TLS; the JVM does NOT
# pick up bind-mounted .crt files on its own - the platform's Acme root
# CA must be IMPORTED into the JVM truststore with keytool. The root CA
# is copied next to this Dockerfile by `make conformance-up` (root-ca.crt,
# from ../../.run/secrets/acme-ca/root-ca.crt) so the build context stays
# self-contained.

ARG IMAGE_TAG=latest
FROM registry.gitlab.com/openid/conformance-suite:${IMAGE_TAG}

USER root
COPY root-ca.crt /tmp/sentin8-root-ca.crt
# Import into the JVM's bundled truststore (cacerts). The base image
# ships Temurin; JAVA_HOME/lib/security/cacerts is the canonical path.
RUN keytool -importcert \
      -noprompt \
      -alias sentin8-root-ca \
      -file /tmp/sentin8-root-ca.crt \
      -keystore "$JAVA_HOME/lib/security/cacerts" \
      -storepass changeit \
 && rm /tmp/sentin8-root-ca.crt
USER 1000