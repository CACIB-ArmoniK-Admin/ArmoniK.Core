using System;
using System.Linq;

using ArmoniK.Core.Common.Exceptions;

using Grpc.Core;

namespace ArmoniK.Core.Common.gRPC;

public static class RpcExt
{
  public static bool HandleExceptions(Exception exception,
                                      StatusCode status)
  {
    switch (exception)
    {
      case RpcException:
        return HandleStatus(status,
                            exception);
      case AggregateException aggregateException:
        return aggregateException.InnerExceptions.All(innerException => HandleExceptions(innerException,
                                                                                           status));
      default:
        return false;
    }
  }

  private static bool HandleStatus(StatusCode status,
                                   Exception exception)
  {
    switch (status)
    {
      case StatusCode.DeadlineExceeded:
        throw new ArmoniK.Core.Common.Exceptions.TimeoutException("Deadline Exceeded",
                        exception);
      case StatusCode.Cancelled:
        throw new TaskCanceledException("Operation Cancelled",
                                        exception);
      case StatusCode.OK:
      case StatusCode.Unknown:
      case StatusCode.Internal:
      case StatusCode.InvalidArgument:
      case StatusCode.NotFound:
      case StatusCode.AlreadyExists:
      case StatusCode.PermissionDenied:
      case StatusCode.Unauthenticated:
      case StatusCode.ResourceExhausted:
      case StatusCode.FailedPrecondition:
      case StatusCode.OutOfRange:
      case StatusCode.Unimplemented:
      case StatusCode.Unavailable:
      case StatusCode.DataLoss:
        return true;
      default:
        return false;
    }
  }
}
