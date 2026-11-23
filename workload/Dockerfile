# syntax=docker/dockerfile:1
# Multi-stage build: compile with Gradle, run on a plain JRE.

FROM gradle:9.2-jdk21 AS build
WORKDIR /src
COPY settings.gradle build.gradle ./
COPY src ./src
# Artifactory credentials arrive as BuildKit secrets: available to this one RUN as env vars,
# never written into an image layer (see `secrets:` in compose.yaml).
RUN --mount=type=secret,id=artifactory_username,env=GEMFIRE_ARTIFACTORY_USERNAME \
    --mount=type=secret,id=artifactory_password,env=GEMFIRE_ARTIFACTORY_PASSWORD \
    --mount=type=cache,target=/home/gradle/.gradle \
    gradle --no-daemon --quiet bootJar

FROM eclipse-temurin:21-jre
RUN useradd --system --uid 10001 --home-dir /app workload
COPY --from=build /src/build/libs/workload.jar /app/workload.jar
USER workload
WORKDIR /app
EXPOSE 8090
ENTRYPOINT ["java", "-jar", "/app/workload.jar"]
