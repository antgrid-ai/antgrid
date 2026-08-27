#include "store_update_channel.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Services.Store.h>

#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::ApplicationModel::PackageVersion;
using winrt::Windows::Services::Store::StoreContext;
using winrt::Windows::Services::Store::StorePackageUpdate;
using winrt::Windows::Services::Store::StorePackageUpdateState;
using winrt::Windows::Services::Store::StorePackageUpdateStatus;

using MethodChannelPtr = flutter::MethodChannel<EncodableValue>*;
using MethodResult =
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

// Wire contract with Dart's WindowsStoreUpdateService — matched literally on
// both sides, so a rename here is a silent no-op there.
constexpr char kProgressMethod[] = "downloadProgress";
constexpr char kOutcomeCompleted[] = "completed";
constexpr char kOutcomeCancelled[] = "cancelled";
constexpr char kOutcomeNone[] = "none";

std::string DescribeError() {
  try {
    throw;
  } catch (winrt::hresult_error const& e) {
    return winrt::to_string(e.message());
  } catch (std::exception const& e) {
    return e.what();
  } catch (...) {
    return "unknown failure";
  }
}

// Unpackaged builds (flutter run, sideloaded exe) have no MSIX package
// identity: GetDefault() yields null rather than throwing, and a projected
// call through null is an access violation catch(...) never sees — convert
// it into the catchable store_unavailable path both coroutines share.
StoreContext RequireStoreContext() {
  StoreContext context = StoreContext::GetDefault();
  if (!context) {
    throw winrt::hresult_error(E_FAIL, L"no package identity");
  }
  return context;
}

std::string FormatPackageVersion(PackageVersion const& version) {
  return std::to_string(version.Major) + "." + std::to_string(version.Minor) +
         "." + std::to_string(version.Build) + "." +
         std::to_string(version.Revision);
}

// Only Completed means the user actually has the new build. Every other
// terminal state — an explicit cancel, and the Store's own error states, which
// this channel has no separate reply for — reports as a cancel: the update
// stays pending and offering it again is the recoverable answer, whereas
// calling it done would record a version that was never installed.
const char* OutcomeFor(StorePackageUpdateState state) {
  return state == StorePackageUpdateState::Completed ? kOutcomeCompleted
                                                     : kOutcomeCancelled;
}

int32_t ProgressPercent(StorePackageUpdateStatus const& status) {
  // TotalDownloadProgress spans every package in the submitted set; the
  // per-package fields describe only the one this callback is about, so they
  // are a fallback for a Store build that leaves the total at zero.
  double fraction = status.TotalDownloadProgress;
  if (!(fraction > 0.0)) {
    fraction = status.PackageDownloadProgress;
  }
  if (!(fraction > 0.0) && status.PackageDownloadSizeInBytes > 0) {
    fraction = static_cast<double>(status.PackageBytesDownloaded) /
               static_cast<double>(status.PackageDownloadSizeInBytes);
  }
  // Negated comparisons so a NaN from the Store lands on 0 rather than
  // propagating through the cast.
  if (!(fraction > 0.0)) return 0;
  if (fraction >= 1.0) return 100;
  return static_cast<int32_t>(fraction * 100.0);
}

// The coroutines below start on the platform (STA) thread, hop to the thread
// pool while a Store async op runs, and must hop back before touching
// |result| or |channel| — the engine's messenger may only be used on the
// platform thread, which keeps pumping messages so the apartment_context
// resume can land.
//
// The hop back is fenced two ways for shutdown: the resume itself sits in a
// try/catch (if the STA is gone it throws, and an exception escaping a
// fire_and_forget is std::terminate), and |alive| is re-checked afterwards —
// the window can close while the async op is in flight, tearing down the
// engine that both the MethodResult and the channel reply through.

// Progress arrives on an arbitrary pool thread, which may touch neither
// |channel| nor |alive|; this carries an already-computed percent across to
// the platform thread under the same fence as the reply paths.
winrt::fire_and_forget EmitDownloadProgress(
    winrt::apartment_context platform_thread, MethodChannelPtr channel,
    std::shared_ptr<bool> alive, int32_t percent) {
  try {
    co_await platform_thread;
  } catch (...) {
    co_return;  // STA gone — process is shutting down, nobody left to tell.
  }
  if (!*alive) co_return;
  channel->InvokeMethod(kProgressMethod,
                        std::make_unique<EncodableValue>(percent));
}

winrt::fire_and_forget CheckForUpdates(MethodResult result,
                                       std::shared_ptr<bool> alive) {
  winrt::apartment_context platform_thread;
  int32_t update_count = 0;
  bool mandatory = false;
  std::string version;
  std::optional<std::string> error;
  try {
    StoreContext context = RequireStoreContext();
    // The only scan a check performs. This call is itself what enqueues the
    // pending update with the Store (its fulfilment events name it), so a
    // second one is a side effect, not a free re-read.
    auto updates =
        co_await context.GetAppAndOptionalStorePackageUpdatesAsync();
    update_count = static_cast<int32_t>(updates.Size());
    for (StorePackageUpdate const& update : updates) {
      // The app's own package leads the list and optional packages follow, so
      // the first entry is the version the user is being offered.
      if (version.empty()) {
        version = FormatPackageVersion(update.Package().Id().Version());
      }
      if (update.Mandatory()) {
        mandatory = true;
      }
    }
  } catch (...) {
    error = DescribeError();
  }
  try {
    co_await platform_thread;
  } catch (...) {
    co_return;  // STA gone — process is shutting down, nobody left to reply to.
  }
  if (!*alive) co_return;
  if (error) {
    result->Error("store_unavailable", *error);
  } else {
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("updateCount"), EncodableValue(update_count)},
        {EncodableValue("mandatory"), EncodableValue(mandatory)},
        {EncodableValue("version"), EncodableValue(version)},
    }));
  }
}

winrt::fire_and_forget DownloadAndInstall(HWND window, MethodChannelPtr channel,
                                          MethodResult result,
                                          std::shared_ptr<bool> alive) {
  winrt::apartment_context platform_thread;
  std::string outcome;
  std::optional<std::string> error;
  try {
    StoreContext context = RequireStoreContext();
    context.as<::IInitializeWithWindow>()->Initialize(window);
    // Re-fetch rather than trusting a stale list from an earlier check — the
    // pending set may have changed while the prompt sat on screen.
    auto updates =
        co_await context.GetAppAndOptionalStorePackageUpdatesAsync();
    if (updates.Size() == 0) {
      outcome = kOutcomeNone;
    } else {
      // The install request must be issued from the UI thread; the scan above
      // resumes wherever WinRT completed it, and requesting off-thread is what
      // leaves the Store's consent dialogs unparented and out of order.
      co_await platform_thread;
      if (!*alive) co_return;
      auto operation =
          context.RequestDownloadAndInstallStorePackageUpdatesAsync(updates);
      auto last_percent = std::make_shared<std::atomic<int32_t>>(-1);
      operation.Progress([platform_thread, channel, alive, last_percent](
                             auto const&,
                             StorePackageUpdateStatus const& status) {
        int32_t percent = ProgressPercent(status);
        // The Store reports per received chunk; whole-percent deltas are all
        // the UI can show and all the binary messenger should carry.
        if (last_percent->exchange(percent) == percent) return;
        EmitDownloadProgress(platform_thread, channel, alive, percent);
      });
      // The Store owns the download/progress UI from here. A mandatory update
      // may terminate the process to install, in which case this never
      // resumes — that is expected.
      auto update_result = co_await operation;
      outcome = OutcomeFor(update_result.OverallState());
    }
  } catch (...) {
    error = DescribeError();
  }
  try {
    co_await platform_thread;
  } catch (...) {
    co_return;  // STA gone — process is shutting down, nobody left to reply to.
  }
  if (!*alive) co_return;
  if (error) {
    result->Error("store_unavailable", *error);
  } else {
    result->Success(EncodableValue(outcome));
  }
}

}  // namespace

StoreUpdateChannel::StoreUpdateChannel(flutter::BinaryMessenger* messenger,
                                       HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "antgrid/store_update",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

StoreUpdateChannel::~StoreUpdateChannel() {
  *alive_ = false;
  // MethodChannel's destructor does NOT deregister the handler from the
  // messenger — without this, a call dispatched during engine teardown would
  // invoke the lambda above with a freed |this|.
  channel_->SetMethodCallHandler(nullptr);
}

void StoreUpdateChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // The coroutines outlive this call frame, so promote to shared ownership.
  MethodResult shared_result(result.release());
  if (call.method_name() == "checkForUpdates") {
    CheckForUpdates(std::move(shared_result), alive_);
  } else if (call.method_name() == "requestDownloadAndInstall") {
    // The raw channel is safe to hand over: it is destroyed on the platform
    // thread by the same destructor that clears |alive_|, which every use of
    // it re-checks after hopping back there.
    DownloadAndInstall(window_, channel_.get(), std::move(shared_result),
                       alive_);
  } else {
    shared_result->NotImplemented();
  }
}
