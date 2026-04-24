// This file is part of the ArmoniK project
//
// Copyright (C) ANEO, 2021-2026. All rights reserved.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY, without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

using System;
using System.Threading;
using System.Threading.Tasks;

using ArmoniK.Api.Common.Channel.Utils;
using ArmoniK.Api.gRPC.V1;
using ArmoniK.Api.gRPC.V1.Worker;
using ArmoniK.Core.Base.DataStructures;
using ArmoniK.Core.Base.Exceptions;
using ArmoniK.Core.Common.gRPC.Convertors;
using ArmoniK.Core.Common.Injection.Options;
using ArmoniK.Core.Common.Storage;

using Grpc.Core;

using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;

using Output = ArmoniK.Core.Common.Storage.Output;

namespace ArmoniK.Core.Common.Stream.Worker;

/// <summary>
///   Handles the interactions with the worker.
/// </summary>
public class WorkerStreamHandler : IWorkerStreamHandler
{
  private readonly GrpcChannelProvider                     channelProvider_;
  private readonly SemaphoreSlim                           initSemaphore_ = new(1, 1);
  private readonly ILogger<WorkerStreamHandler>            logger_;
  private readonly InitWorker                              optionsInitWorker_;
  private volatile bool                                    isInitialized_;
  private volatile Api.gRPC.V1.Worker.Worker.WorkerClient? workerClient_;

  /// <summary>
  ///   Initializes a new instance of the <see cref="WorkerStreamHandler" /> class.
  /// </summary>
  /// <param name="channelProvider">The gRPC channel provider.</param>
  /// <param name="optionsInitWorker">The initialization options for the worker.</param>
  /// <param name="logger">The logger instance.</param>
  public WorkerStreamHandler(GrpcChannelProvider          channelProvider,
                             InitWorker                   optionsInitWorker,
                             ILogger<WorkerStreamHandler> logger)
  {
    channelProvider_   = channelProvider;
    optionsInitWorker_ = optionsInitWorker;
    logger_            = logger;
  }

  /// <inheritdoc />
  public async Task Init(CancellationToken cancellationToken)
  {
    if (isInitialized_)
    {
      return;
    }

    await initSemaphore_.WaitAsync(cancellationToken)
                        .ConfigureAwait(false);
    try
    {
      if (isInitialized_)
      {
        return;
      }

      // Note: Per-call transient gRPC failures (Unavailable, Internal) are handled
      // by the native gRPC retry policy configured on the channel (ServiceConfig).
      // This Init retry loop only waits for the worker process to become available at startup
      // or after a connection loss detected in StartTaskProcessing.
      // See: https://learn.microsoft.com/en-us/aspnet/core/grpc/retries
      for (var retry = 1; retry < optionsInitWorker_.WorkerCheckRetries; ++retry)
      {
        try
        {
          var channel = channelProvider_.Get();
          workerClient_ = new Api.gRPC.V1.Worker.Worker.WorkerClient(channel);

          var check = await CheckWorker(cancellationToken)
                        .ConfigureAwait(false);

          if (!check)
          {
            throw new ArmoniKException("Worker Health Check was not successful");
          }

          isInitialized_ = true;
          return;
        }
        catch (Exception ex)
        {
          logger_.LogError(ex,
                           "Failed to create worker channel, retry in {seconds}",
                           optionsInitWorker_.WorkerCheckDelay * retry);
          await Task.Delay(optionsInitWorker_.WorkerCheckDelay * retry,
                           cancellationToken)
                    .ConfigureAwait(false);
        }
      }

      var e = new ArmoniKException("Could not get grpc channel");
      logger_.LogError(e,
                       "Could not get grpc channel");
      throw e;
    }
    finally
    {
      initSemaphore_.Release();
    }
  }

  /// <inheritdoc />
  public async Task<HealthCheckResult> Check(HealthCheckTag tag)
  {
    try
    {
      if (!isInitialized_)
      {
        return HealthCheckResult.Unhealthy("Worker not yet initialized");
      }

      var check = await CheckWorker(CancellationToken.None)
                    .ConfigureAwait(false);

      if (!check)
      {
        return HealthCheckResult.Unhealthy("Health check on worker was not successful (too many retries)");
      }

      return HealthCheckResult.Healthy();
    }
    catch (Exception ex)
    {
      return HealthCheckResult.Unhealthy("Health check on worker was not successful with exception",
                                         ex);
    }
  }

  /// <inheritdoc />
  public void Dispose()
  {
    initSemaphore_.Dispose();
    GC.SuppressFinalize(this);
  }

  /// <inheritdoc />
  public async Task<Output> StartTaskProcessing(TaskData          taskData,
                                                string            token,
                                                string            dataFolder,
                                                Configuration     configuration,
                                                CancellationToken cancellationToken)
  {
    if (workerClient_ is null)
    {
      throw new ArmoniKException("Worker client should be initialized");
    }

    try
    {
      return await SendProcessRequestAsync(taskData,
                                           token,
                                           dataFolder,
                                           configuration,
                                           cancellationToken)
               .ConfigureAwait(false);
    }
    catch (RpcException e) when (e.StatusCode is StatusCode.Unavailable)
    {
      // Do NOT retry the task here. When the connection is lost mid-execution, we cannot
      // determine whether the worker received and started processing the request.
      // Retrying would risk executing the same task twice (duplicate side-effects, double
      // result writes) if the worker is still alive but the network dropped transiently.
      //
      // Instead, propagate the exception to TaskHandler so it safely requeues the task
      // to another pod via the task state machine.
      //
      // However, we must still reconnect before throwing so that the next task picked up
      // by this polling agent can be processed. Pollster.Init() is only called once at
      // startup, so without this reconnect the worker client would remain null and all
      // subsequent tasks would fail with "Worker client should be initialized".
      logger_.LogWarning(e,
                         "Worker connection lost during task processing. Reconnecting for future tasks and propagating to TaskHandler for safe requeue of current task");

      isInitialized_ = false;
      workerClient_  = null;

      // Use an independent timeout for reconnection so that a cancelled task token
      // (e.g. lateCts already fired due to the grace delay expiring) does not prevent
      // the worker from being reconnected after a crash/restart.
      // The timeout is bounded by WorkerCheckRetries × WorkerCheckDelay so it cannot
      // block indefinitely.
      var reconnectTimeout = TimeSpan.FromSeconds(optionsInitWorker_.WorkerCheckRetries * optionsInitWorker_.WorkerCheckDelay.TotalSeconds);
      using var reconnectCts = new CancellationTokenSource(reconnectTimeout);

      try
      {
        await Init(reconnectCts.Token)
          .ConfigureAwait(false);
        logger_.LogInformation("Reconnected to worker after connection loss");
      }
      catch (Exception reconnectEx)
      {
        // Reconnection failed — log and continue to throw the original exception.
        // The health check will eventually mark this pod as unhealthy and it will
        // be restarted by the orchestrator.
        logger_.LogError(reconnectEx,
                         "Failed to reconnect to worker after connection loss. Pod will be marked unhealthy");
      }

      throw;
    }
  }

  /// <summary>
  ///   Sends the process request to the worker and converts the response to an internal output.
  /// </summary>
  private async Task<Output> SendProcessRequestAsync(TaskData          taskData,
                                                     string            token,
                                                     string            dataFolder,
                                                     Configuration     configuration,
                                                     CancellationToken cancellationToken)
  {
    if (workerClient_ is null)
    {
      throw new ArmoniKException("Worker client should be initialized");
    }

    try
    {
      return (await workerClient_.ProcessAsync(new ProcessRequest
                                               {
                                                 CommunicationToken = token,
                                                 Configuration      = configuration,
                                                 DataDependencies =
                                                 {
                                                   taskData.DataDependencies,
                                                 },
                                                 DataFolder = dataFolder,
                                                 ExpectedOutputKeys =
                                                 {
                                                   taskData.ExpectedOutputIds,
                                                 },
                                                 PayloadId   = taskData.PayloadId,
                                                 SessionId   = taskData.SessionId,
                                                 TaskId      = taskData.TaskId,
                                                 TaskOptions = taskData.Options.ToGrpcTaskOptions(),
                                               },
                                               deadline: DateTime.UtcNow + taskData.Options.MaxDuration,
                                               cancellationToken: cancellationToken)
                                 .ConfigureAwait(false)).Output.ToInternalOutput();
    }
    catch (RpcException e) when (e.StatusCode is StatusCode.DeadlineExceeded)
    {
      return new Output(OutputStatus.Timeout,
                        "Deadline Exceeded");
    }
  }

  /// <summary>
  ///   Checks the health of the worker.
  /// </summary>
  /// <param name="cancellationToken">The cancellation token.</param>
  /// <returns>
  ///   A task that represents the asynchronous operation. The task result contains a boolean indicating the health
  ///   status of the worker.
  /// </returns>
  private Task<bool> CheckWorker(CancellationToken cancellationToken)
  {
    try
    {
      if (workerClient_ is null)
      {
        return Task.FromResult(false);
      }

      var reply = workerClient_.HealthCheck(new Empty(),
                                            cancellationToken: cancellationToken);
      if (reply.Status != HealthCheckReply.Types.ServingStatus.Serving)
      {
        return Task.FromResult(false);
      }

      logger_.LogDebug("Channel was initialized");
      return Task.FromResult(true);
    }
    catch (RpcException ex) when (ex.StatusCode == StatusCode.Unimplemented)
    {
      logger_.LogDebug("Channel was initialized but Worker health check is not implemented");
      return Task.FromResult(true);
    }
  }
}
