# Build ICU 78.2 (fixes CVE-2025-5222) with GCC 13 so its C++ ABI matches /usr/qlib-libcpp/libstdc++.so.6.
FROM --platform=$BUILDPLATFORM docker-remote.registry.saas.cagip.group.gca/gcc:13-bookworm AS icu-build
COPY certs/rca_credit_agricole_group.crt /tmp/rca_credit_agricole_group.crt
COPY certs/cacreditagricoleserver.crt /tmp/cacreditagricoleserver.crt
RUN tr -d '\r' < /tmp/rca_credit_agricole_group.crt >> /etc/ssl/certs/ca-certificates.crt \
 && tr -d '\r' < /tmp/cacreditagricoleserver.crt >> /etc/ssl/certs/ca-certificates.crt \
 && curl -fsSL --noproxy '*' "https://registry.saas.cagip.group.gca/artifactory/codeload-remote/unicode-org/icu/tar.gz/release-78.2" \
    | tar -xz -C /tmp \
 && cd /tmp/icu-release-78.2/icu4c/source \
 && ./configure \
      --prefix=/opt/icu \
      --enable-shared \
      --disable-static \
      --disable-samples \
      --disable-tests \
      --disable-extras \
      --disable-icuio \
      --disable-layoutex \
 && make -j"$(nproc)" \
 && make install

FROM docker-remote-microsoft-dotnet.registry.saas.cagip.group.gca:443/dotnet/aspnet:10.0 AS base-linux-setup
RUN echo "armonikuser:x:5000:5000::/home/armonikuser:/bin/sh" >> /etc/passwd \
 && echo "armonikuser:x:5000:" >> /etc/group \
 && mkdir -p /home/armonikuser /cache /local_storage /comm \
 && chown 5000:5000 /home/armonikuser /cache /local_storage /comm

FROM docker-remote-microsoft-dotnet.registry.saas.cagip.group.gca:443/dotnet/aspnet:10.0 AS base-linux
COPY --from=base-linux-setup /etc/passwd /etc/passwd
COPY --from=base-linux-setup /etc/group /etc/group
COPY --from=base-linux-setup --chown=5000:5000 /home/armonikuser /home/armonikuser
COPY --from=base-linux-setup --chown=5000:5000 /cache /cache
COPY --from=base-linux-setup --chown=5000:5000 /local_storage /local_storage
COPY --from=base-linux-setup --chown=5000:5000 /comm /comm
COPY --from=icu-build /opt/icu/lib/libicudata.so* /opt/icu/lib/libicuuc.so* /opt/icu/lib/libicui18n.so* /usr/lib/x86_64-linux-gnu/
# Point /bin/sh to bash (0 CVE) and purge unpatched Ubuntu Noble packages unused at runtime.
RUN sed -i '\|/sh$|d; \|/sh\.1|d' /var/lib/dpkg/info/dash.list \
 && rm -f /var/lib/dpkg/info/dash.postrm /var/lib/dpkg/info/dash.prerm \
 && ln -sf /bin/bash /bin/sh && ln -sf /usr/bin/bash /usr/bin/sh \
 && dpkg --purge --force-depends --force-remove-essential \
      apt libapt-pkg6.0t64 gpgv libgnutls30t64 \
      tar passwd login \
      procps libproc2-0 e2fsprogs logsave libext2fs2t64 libss2 libcom-err2 \
      libpam-modules libpam-modules-bin \
      bsdutils mount util-linux libuuid1 libblkid1 libmount1 libsmartcols1 \
      libsystemd0 libudev1 \
      dash \
      libicu74 \
 && rm -rf /var/lib/apt /var/log/apt /etc/apt \
 && ldconfig
USER 5000
ENTRYPOINT [ "dotnet" ]

FROM --platform=$BUILDPLATFORM docker-remote-microsoft-dotnet.registry.saas.cagip.group.gca:443/dotnet/sdk:10.0 AS build-linux
# Install corporate CA certificates so dotnet restore can reach the internal Artifactory NuGet proxy
COPY certs/rca_credit_agricole_group.crt /tmp/rca_credit_agricole_group.crt
COPY certs/cacreditagricoleserver.crt /tmp/cacreditagricoleserver.crt
RUN tr -d '\r' < /tmp/rca_credit_agricole_group.crt >> /etc/ssl/certs/ca-certificates.crt \
 && tr -d '\r' < /tmp/cacreditagricoleserver.crt >> /etc/ssl/certs/ca-certificates.crt

FROM build-linux AS build
ARG VERSION=1.0.0.0
ARG TARGETARCH
ARG NUGET_ARTIFACTORY_USER
ARG NUGET_ARTIFACTORY_PASSWORD

WORKDIR /src
# git ls-tree -r HEAD --name-only --full-tree | grep "csproj$" | xargs -I % sh -c "export D=\$(dirname %) ; echo COPY [\\\"%\\\", \\\"\$D/\\\"]"
COPY ["Adaptors/Amqp/src/ArmoniK.Core.Adapters.Amqp.csproj", "Adaptors/Amqp/src/"]
COPY ["Adaptors/LocalStorage/src/ArmoniK.Core.Adapters.LocalStorage.csproj", "Adaptors/LocalStorage/src/"]
COPY ["Adaptors/Memory/src/ArmoniK.Core.Adapters.Memory.csproj", "Adaptors/Memory/src/"]
COPY ["Adaptors/MongoDB/src/ArmoniK.Core.Adapters.MongoDB.csproj", "Adaptors/MongoDB/src/"]
COPY ["Adaptors/Couchbase/src/ArmoniK.Core.Adapters.Couchbase.csproj", "Adaptors/Couchbase/src/"]
COPY ["Adaptors/QueueCommon/src/ArmoniK.Core.Adapters.QueueCommon.csproj", "Adaptors/QueueCommon/src/"]
COPY ["Adaptors/PubSub/src/ArmoniK.Core.Adapters.PubSub.csproj", "Adaptors/PubSub/src/"]
COPY ["Adaptors/Redis/src/ArmoniK.Core.Adapters.Redis.csproj", "Adaptors/Redis/src/"]
COPY ["Adaptors/S3/src/ArmoniK.Core.Adapters.S3.csproj", "Adaptors/S3/src/"]
COPY ["Adaptors/SQS/src/ArmoniK.Core.Adapters.SQS.csproj", "Adaptors/SQS/src/"]
COPY ["Adaptors/Embed/src/ArmoniK.Core.Adapters.Embed.csproj", "Adaptors/Embed/src/"]
COPY ["Base/src/ArmoniK.Core.Base.csproj", "Base/src/"]
COPY ["Common/src/ArmoniK.Core.Common.csproj", "Common/src/"]
COPY ["Compute/PollingAgent/src/ArmoniK.Core.Compute.PollingAgent.csproj", "Compute/PollingAgent/src/"]
COPY ["Control/Metrics/src/ArmoniK.Core.Control.Metrics.csproj", "Control/Metrics/src/"]
COPY ["Control/Submitter/src/ArmoniK.Core.Control.Submitter.csproj", "Control/Submitter/src/"]
COPY ["Utils/src/ArmoniK.Core.Utils.csproj", "Utils/src/"]

# nuget.config declares the internal Artifactory NuGet proxy.
COPY ["nuget.config", "."]

RUN dotnet restore -a "${TARGETARCH}" "Compute/PollingAgent/src/ArmoniK.Core.Compute.PollingAgent.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Control/Metrics/src/ArmoniK.Core.Control.Metrics.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Control/Submitter/src/ArmoniK.Core.Control.Submitter.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/Amqp/src/ArmoniK.Core.Adapters.Amqp.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/PubSub/src/ArmoniK.Core.Adapters.PubSub.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/SQS/src/ArmoniK.Core.Adapters.SQS.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/S3/src/ArmoniK.Core.Adapters.S3.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/LocalStorage/src/ArmoniK.Core.Adapters.LocalStorage.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/Redis/src/ArmoniK.Core.Adapters.Redis.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/Couchbase/src/ArmoniK.Core.Adapters.Couchbase.csproj"
RUN dotnet restore -a "${TARGETARCH}" "Adaptors/Embed/src/ArmoniK.Core.Adapters.Embed.csproj"

# git ls-tree -r HEAD --name-only --full-tree | grep "csproj$" | xargs -I % sh -c "export D=\$(dirname %) ; echo COPY [\\\"\$D\\\", \\\"\$D\\\"]"
COPY ["Adaptors/Amqp/src", "Adaptors/Amqp/src"]
COPY ["Adaptors/LocalStorage/src", "Adaptors/LocalStorage/src"]
COPY ["Adaptors/Memory/src", "Adaptors/Memory/src"]
COPY ["Adaptors/MongoDB/src", "Adaptors/MongoDB/src"]
COPY ["Adaptors/Couchbase/src", "Adaptors/Couchbase/src"]
COPY ["Adaptors/QueueCommon/src", "Adaptors/QueueCommon/src"]
COPY ["Adaptors/PubSub/src", "Adaptors/PubSub/src"]
COPY ["Adaptors/Redis/src", "Adaptors/Redis/src"]
COPY ["Adaptors/S3/src", "Adaptors/S3/src"]
COPY ["Adaptors/SQS/src", "Adaptors/SQS/src"]
COPY ["Adaptors/Embed/src", "Adaptors/Embed/src"]
COPY ["Base/src", "Base/src"]
COPY ["Common/src", "Common/src"]
COPY ["Compute/PollingAgent/src", "Compute/PollingAgent/src"]
COPY ["Control/Metrics/src", "Control/Metrics/src"]
COPY ["Control/Submitter/src", "Control/Submitter/src"]
COPY ["Utils/src", "Utils/src"]

WORKDIR /src/Adaptors/SQS/src
RUN dotnet publish "ArmoniK.Core.Adapters.SQS.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/sqs /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/PubSub/src
RUN dotnet publish "ArmoniK.Core.Adapters.PubSub.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/pubsub /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/Amqp/src
RUN dotnet publish "ArmoniK.Core.Adapters.Amqp.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/amqp /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/LocalStorage/src
RUN dotnet publish "ArmoniK.Core.Adapters.LocalStorage.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/local_storage /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/Embed/src
RUN dotnet publish "ArmoniK.Core.Adapters.Embed.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/embed /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/Redis/src
RUN dotnet publish "ArmoniK.Core.Adapters.Redis.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/redis /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/S3/src
RUN dotnet publish "ArmoniK.Core.Adapters.S3.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/s3 /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Adaptors/Couchbase/src
RUN dotnet publish "ArmoniK.Core.Adapters.Couchbase.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/couchbase /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Compute/PollingAgent/src
RUN dotnet publish "ArmoniK.Core.Compute.PollingAgent.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/polling_agent /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Control/Metrics/src
RUN dotnet publish "ArmoniK.Core.Control.Metrics.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/metrics /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

WORKDIR /src/Control/Submitter/src
RUN dotnet publish "ArmoniK.Core.Control.Submitter.csproj" -a "${TARGETARCH}" --no-restore -o /app/publish/submitter /p:UseAppHost=false -p:RunAnalyzers=false -p:WarningLevel=0 -p:PackageVersion=$VERSION -p:Version=$VERSION

# Remove unused SharpCompress (pulled transitively by MongoDB.Driver.Core for optional zlib wire compression) from published outputs and .deps.json.
WORKDIR /src
RUN find /app/publish -iname 'SharpCompress*' -delete \
 && cat <<'EOF' > /src/strip_sharpcompress.cs
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

foreach (var path in Directory.GetFiles("/app/publish", "*.deps.json", SearchOption.AllDirectories))
{
    var root = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    if (root["targets"] is JsonObject targets)
    {
        foreach (var (_, targetVal) in targets)
        {
            if (targetVal is not JsonObject libs) continue;
            foreach (var key in libs.Select(kv => kv.Key).Where(k => k.StartsWith("SharpCompress/", System.StringComparison.OrdinalIgnoreCase)).ToList())
                libs.Remove(key);
            foreach (var (_, libVal) in libs)
            {
                if (libVal?["dependencies"] is JsonObject deps)
                    foreach (var dk in deps.Select(kv => kv.Key).Where(k => k.Equals("SharpCompress", System.StringComparison.OrdinalIgnoreCase)).ToList())
                        deps.Remove(dk);
            }
        }
    }
    if (root["libraries"] is JsonObject libraries)
    {
        foreach (var key in libraries.Select(kv => kv.Key).Where(k => k.StartsWith("SharpCompress/", System.StringComparison.OrdinalIgnoreCase)).ToList())
            libraries.Remove(key);
    }
    File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
}
EOF
RUN dotnet /src/strip_sharpcompress.cs && rm -f /src/strip_sharpcompress.cs


FROM base-linux AS polling_agent
WORKDIR /adapters/queue/sqs
COPY --from=build /app/publish/sqs .
WORKDIR /adapters/queue/pubsub
COPY --from=build /app/publish/pubsub .
WORKDIR /adapters/queue/amqp
COPY --from=build /app/publish/amqp .
WORKDIR /adapters/object/local_storage
COPY --from=build /app/publish/local_storage .
WORKDIR /adapters/object/redis
COPY --from=build /app/publish/redis .
WORKDIR /adapters/object/embed
COPY --from=build /app/publish/embed .
WORKDIR /adapters/object/s3
COPY --from=build /app/publish/s3 .
WORKDIR /adapters/object/couchbase
COPY --from=build /app/publish/couchbase .
WORKDIR /app
COPY --from=build /app/publish/polling_agent .
ENV ASPNETCORE_URLS http://+:1080
EXPOSE 1080
CMD ["ArmoniK.Core.Compute.PollingAgent.dll"]


FROM base-linux AS metrics
WORKDIR /app
COPY --from=build /app/publish/metrics .
ENV ASPNETCORE_URLS http://+:1080
EXPOSE 1080
CMD ["ArmoniK.Core.Control.Metrics.dll"]


FROM base-linux AS submitter
WORKDIR /adapters/queue/sqs
COPY --from=build /app/publish/sqs .
WORKDIR /adapters/queue/pubsub
COPY --from=build /app/publish/pubsub .
WORKDIR /adapters/queue/amqp
COPY --from=build /app/publish/amqp .
WORKDIR /adapters/object/local_storage
COPY --from=build /app/publish/local_storage .
WORKDIR /adapters/object/redis
COPY --from=build /app/publish/redis .
WORKDIR /adapters/object/embed
COPY --from=build /app/publish/embed .
WORKDIR /adapters/object/s3
COPY --from=build /app/publish/s3 .
WORKDIR /adapters/object/couchbase
COPY --from=build /app/publish/couchbase .
WORKDIR /app
COPY --from=build /app/publish/submitter .
ENV ASPNETCORE_URLS http://+:1080, http://+:1081
EXPOSE 1080
EXPOSE 1081
CMD ["ArmoniK.Core.Control.Submitter.dll"]
