#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

// Passed back to us on the command line when Windows relaunches the process
// after applying a Store update. Nothing in Dart reads it, deliberately: the
// same argument comes back after a crash, a hang and a reboot-to-patch, so it
// is not evidence an update happened. The version UpdateHandoffStore records
// at hand-off is (app/lib/storage/update_handoff_store.dart). The registration
// still needs a command line, and this one names the case it exists for.
constexpr const wchar_t kRestartCommandLine[] = L"--after-update";

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Forward any app link to an already-running instance and exit — no second
  // window. app_links enumerates EVERY runner window and matches on this exact
  // executable, so distinct builds coexist (a dev build beside the Store
  // install) without one shadowing the other: a first-match FindWindow on
  // class + title gave up whenever the other build's window came first, and
  // the relaunch then opened a second copy of this one.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // A Store update force-kills this process (ForceTargetApplicationShutdown),
  // so without a restart registration the user is simply left with no app.
  // The flags must stay 0: every RESTART_NO_* bit subtracts a case Windows
  // would otherwise relaunch us for, patching included. Windows honours the
  // registration only once the process has been alive ~60s, which any
  // user-initiated update click is well past.
  HRESULT restart_registration =
      ::RegisterApplicationRestart(kRestartCommandLine, 0);
  if (FAILED(restart_registration)) {
    wchar_t warning[160];
    ::wsprintfW(warning,
                L"antgrid: RegisterApplicationRestart failed (0x%08X); the app "
                L"will not relaunch itself after a Store update",
                restart_registration);
    ::OutputDebugStringW(warning);
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"antgrid", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
