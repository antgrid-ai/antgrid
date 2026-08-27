#ifndef RUNNER_STORE_UPDATE_CHANNEL_H_
#define RUNNER_STORE_UPDATE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Bridges Dart's WindowsStoreUpdateService ("antgrid/store_update") to the
// WinRT StoreContext API. StoreContext only works with MSIX package identity
// (Store-installed builds); without it every call replies with a
// "store_unavailable" error that the Dart side degrades to "no update".
//
// Inbound: "checkForUpdates" -> {updateCount, mandatory, version};
// "requestDownloadAndInstall" -> "completed" | "cancelled" | "none".
// Outbound: "downloadProgress" carries an int percent (0-100) while an install
// is in flight.
class StoreUpdateChannel {
 public:
  // |messenger| and |window| must outlive this object.
  StoreUpdateChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~StoreUpdateChannel();

  StoreUpdateChannel(const StoreUpdateChannel&) = delete;
  StoreUpdateChannel& operator=(const StoreUpdateChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // Owning top-level window, needed to parent the Store's install UI
  // (IInitializeWithWindow) — desktop apps have no CoreWindow.
  HWND window_;
  // Cleared by the destructor. In-flight Store coroutines outlive the channel
  // (their async ops run for seconds to minutes on the thread pool); each one
  // re-checks this after hopping back to the platform thread so it never
  // replies through an engine that was torn down while it was away, and the
  // progress emitter re-checks it for the same reason before dereferencing
  // |channel_|. Only ever touched on the platform thread, so a plain bool is
  // race-free.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
};

#endif  // RUNNER_STORE_UPDATE_CHANNEL_H_
