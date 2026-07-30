#include "store_update_channel.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Services.Store.h>

#include <optional>
#include <string>
#include <utility>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Services::Store::StoreContext;
using winrt::Windows::Services::Store::StorePackageUpdate;
using winrt::Windows::Services::Store::StorePackageUpdateState;

using MethodResult =
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

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

// Both coroutines below run on the platform (STA) thread, hop to the thread
// pool while the Store async op runs, and must hop back before touching
// |result| — method results may only be invoked on the platform thread, which
// keeps pumping messages so the apartment_context resume can land.
//
// The hop back is fenced two ways for shutdown: the resume itself sits in a
// try/catch (if the STA is gone it throws, and an exception escaping a
// fire_and_forget is std::terminate), and |alive| is re-checked afterwards —
// the window can close while the async op is in flight, tearing down the
// engine whose messenger the MethodResult replies through.

winrt::fire_and_forget CheckForUpdates(MethodResult result,
                                       std::shared_ptr<bool> alive) {
  winrt::apartment_context platform_thread;
  int32_t update_count = 0;
  bool mandatory = false;
  std::optional<std::string> error;
  try {
    StoreContext context = RequireStoreContext();
    auto updates =
        co_await context.GetAppAndOptionalStorePackageUpdatesAsync();
    update_count = static_cast<int32_t>(updates.Size());
    for (StorePackageUpdate const& update : updates) {
      if (update.Mandatory()) {
        mandatory = true;
        break;
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
    }));
  }
}

winrt::fire_and_forget DownloadAndInstall(HWND window, MethodResult result,
                                          std::shared_ptr<bool> alive) {
  winrt::apartment_context platform_thread;
  bool completed = false;
  std::optional<std::string> error;
  try {
    StoreContext context = RequireStoreContext();
    context.as<::IInitializeWithWindow>()->Initialize(window);
    // Re-fetch rather than trusting a stale list from an earlier check — the
    // pending set may have changed while the prompt sat on screen.
    auto updates =
        co_await context.GetAppAndOptionalStorePackageUpdatesAsync();
    if (updates.Size() > 0) {
      // The Store owns the download/progress UI from here. A mandatory update
      // may terminate the process to install, in which case this never
      // resumes — that is expected.
      auto update_result =
          co_await context.RequestDownloadAndInstallStorePackageUpdatesAsync(
              updates);
      completed =
          update_result.OverallState() == StorePackageUpdateState::Completed;
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
    result->Success(EncodableValue(completed));
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
    DownloadAndInstall(window_, std::move(shared_result), alive_);
  } else {
    shared_result->NotImplemented();
  }
}
