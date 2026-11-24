# syntax=docker/dockerfile:1
# Multi-stage build: compile with Gradle, run on a plain JRE. (Like workload/Dockerfile, minus the
# Artifactory secrets: every dependency here is on Maven Central.)

FROM gradle:9.2-jdk21 AS build
WORKDIR /src
COPY settings.gradle build.gradle ./
COPY src ./src
RUN --mount=type=cache,target=/home/gradle/.gradle \
    gradle --no-daemon --quiet bootJar

FROM eclipse-temurin:21-jre
RUN useradd --system --uid 10001 --home-dir /app sre
COPY --from=build /src/build/libs/sre-assistant.jar /app/sre-assistant.jar
USER sre
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/sre-assistant.jar"]
