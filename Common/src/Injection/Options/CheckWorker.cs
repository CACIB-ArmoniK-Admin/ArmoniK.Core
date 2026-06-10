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

using ArmoniK.Utils.DocAttribute;

namespace ArmoniK.Core.Common.Injection.Options;

/// <summary>
///   Configuration for the periodic health check retries in <see cref="Stream.Worker.WorkerStreamHandler" />
/// </summary>
[ExtractDocumentation("Options for CheckWorker")]
public class CheckWorker
{
  /// <summary>
  ///   Path to the section containing the values in the configuration object
  /// </summary>
  public const string SettingSection = nameof(CheckWorker);

  /// <summary>
  ///   Number of times the health check should retry before reporting unhealthy.
  /// </summary>
  public int WorkerCheckRetries { get; set; } = 5;

  /// <summary>
  ///   Base delay duration between each retry attempt (used with exponential backoff).
  /// </summary>
  public TimeSpan WorkerCheckDelay { get; set; } = TimeSpan.FromSeconds(2);
}

