#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

// Window class + title alone aren't enough to identify "our" instance: every
// antgrid build (dev debug build, a locally installed release, the packaged
// MSIX) produces a window with this same class and title, so a naive
// FindWindow match forwards app-links into — and exits in favor of — a
// window owned by a completely different build. Require the found window's
// owning process to be running from this exact executable, so distinct
// builds/installs can coexist (e.g. developing antgrid while the installed
// build stays open).
bool IsSameExecutable(HWND hwnd) {
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) {
    return false;
  }

  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) {
    return false;
  }

  wchar_t other_path[MAX_PATH];
  DWORD other_path_len = MAX_PATH;
  BOOL got_path = ::QueryFullProcessImageNameW(process, 0, other_path, &other_path_len);
  ::CloseHandle(process);
  if (!got_path) {
    return false;
  }

  wchar_t self_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, self_path, MAX_PATH) == 0) {
    return false;
  }

  return ::_wcsicmp(self_path, other_path) == 0;
}

bool SendAppLinkToInstance(const std::wstring& title) {
  // Find our exact window
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());

  if (hwnd && IsSameExecutable(hwnd)) {
    // Dispatch new link to current window
    SendAppLink(hwnd);

    // (Optional) Restore our window to front in same state
    WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
    GetWindowPlacement(hwnd, &place);

    switch(place.showCmd) {
      case SW_SHOWMAXIMIZED:
          ShowWindow(hwnd, SW_SHOWMAXIMIZED);
          break;
      case SW_SHOWMINIMIZED:
          ShowWindow(hwnd, SW_RESTORE);
          break;
      default:
          ShowWindow(hwnd, SW_NORMAL);
          break;
    }

    SetWindowPos(0, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    SetForegroundWindow(hwnd);
    // END (Optional) Restore

    // Window has been found, don't create another one.
    return true;
  }

  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // If an app_links URL is being dispatched to an already-running instance,
  // forward it and exit — no second window.
  if (SendAppLinkToInstance(L"antgrid")) {
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
