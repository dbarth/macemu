/*
 *	utils_macosx.mm - Mac OS X utility functions.
 *
 *  Copyright (C) 2011 Alexei Svitkine
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include <Cocoa/Cocoa.h>
#include "sysdeps.h"
#include <SDL.h>
#include "utils_macosx.h"

#if SDL_VERSION_ATLEAST(2, 0, 0) && !SDL_VERSION_ATLEAST(3, 0, 0)
#include <SDL_syswm.h>
#endif

#include <sys/sysctl.h>
#include <IOSurface/IOSurface.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <errno.h>
#include <signal.h>

// ---- the guest's screen, published ---------------------------------------

// Sends to one connection, or to every open one when `only` is -1.
static void announce_surface(int only);

static IOSurfaceRef shared_frame = NULL;
// Set while the surface holds nothing drawn: the next copy carries the whole
// screen. Every other copy carries the dirty rect.
static bool shared_frame_stale = true;

void close_shared_frame_osx()
{
	if (!shared_frame) return;
	CFRelease(shared_frame);
	shared_frame = NULL;
}

static void put_surface_number(CFMutableDictionaryRef d, CFStringRef key, int value)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &value);
	CFDictionarySetValue(d, key, n);
	CFRelease(n);
}

bool open_shared_frame_osx(int width, int height)
{
	close_shared_frame_osx();

	CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	put_surface_number(props, kIOSurfaceWidth, width);
	put_surface_number(props, kIOSurfaceHeight, height);
	put_surface_number(props, kIOSurfaceBytesPerElement, 4);
	put_surface_number(props, kIOSurfacePixelFormat, 'BGRA');
	// Readers can look up a surface only if it is marked global.
	CFDictionarySetValue(props, kIOSurfaceIsGlobal, kCFBooleanTrue);
	shared_frame = IOSurfaceCreate(props);
	CFRelease(props);
	if (!shared_frame) {
		printf("WARNING: could not create the shared frame surface\n");
		return false;
	}

	shared_frame_stale = true;
	// Give every connection the new id. The surface they draw is gone.
	announce_surface(-1);
	return true;
}

// ---- the control socket ---------------------------------------------------
//
// A unix socket takes one line of JSON per command. A reader thread queues it
// and handle_events drains the queue: only the SDL thread touches SDL and ADB.

static int control_socket = -1;
static char control_path[1024] = "";
#define CONTROL_QUEUE 512
static control_op control_queue[CONTROL_QUEUE];
static unsigned control_in = 0, control_out = 0;
static pthread_mutex_t control_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t control_room = PTHREAD_COND_INITIALIZER;

// How many connections have asked for frames. Closing a connection drops its
// count, and a crashed reader closes its connection.
static int watchers = 0;

// Every open connection. A change of resolution or depth replaces the surface
// and announces the new id to all of them.
#define CONTROL_MAX 8
static int connections[CONTROL_MAX];
static int connection_count = 0;

/// Queues one command and waits up to a second for room. A lost key-up stays
/// set in the guest's key matrix until reboot. See `key_states` in `adb.cpp`.
static void queue_control(control_op op)
{
	pthread_mutex_lock(&control_lock);
	while (control_in - control_out >= CONTROL_QUEUE) {
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += 1;
		if (pthread_cond_timedwait(&control_room, &control_lock, &until) != 0)
			break;						// a second without a drain: drop this one
	}
	if (control_in - control_out < CONTROL_QUEUE)
		control_queue[control_in++ % CONTROL_QUEUE] = op;
	else
		free(op.text);					// nothing takes it off the queue now
	pthread_mutex_unlock(&control_lock);
}

bool next_control_op_osx(control_op *op)
{
	pthread_mutex_lock(&control_lock);
	bool any = control_in != control_out;
	if (any) *op = control_queue[control_out++ % CONTROL_QUEUE];
	pthread_mutex_unlock(&control_lock);
	if (any) pthread_cond_signal(&control_room);
	return any;
}

static void queue_op(int what)
{
	control_op op = { what, 0, 0, false, NULL };
	queue_control(op);
}

/// Whether this line names `op`. Reads the value after "op" at any spacing.
static bool line_says(const char *line, const char *op)
{
	const char *at = strstr(line, "\"op\"");
	if (!at) return false;
	at = strchr(at + 4, ':');
	if (!at) return false;
	while (*at == ':' || *at == ' ' || *at == '\t') at++;
	if (*at != '"') return false;
	at++;
	size_t n = strlen(op);
	return strncmp(at, op, n) == 0 && at[n] == '"';
}

/// Sends the surface id and size to one connection as it arrives, and to all
/// of them on a video mode change. The old id draws nothing.
static void announce_surface(int only)
{
	if (!shared_frame) return;
	char line[160];
	int n = snprintf(line, sizeof(line),
					 "{\"ev\":\"surface\",\"id\":%u,\"width\":%zu,\"height\":%zu}\n",
					 (unsigned)IOSurfaceGetID(shared_frame),
					 IOSurfaceGetWidth(shared_frame), IOSurfaceGetHeight(shared_frame));
	pthread_mutex_lock(&control_lock);
	for (int i = 0; i < connection_count; i++)
		if (only < 0 || connections[i] == only)
			(void)write(connections[i], line, n);
	pthread_mutex_unlock(&control_lock);
}

/// Sends whether the window is on screen, on every change. The close widget
/// can take the window away while a client is watching.
static void announce_window(bool shown)
{
	char line[64];
	int n = snprintf(line, sizeof(line),
					 "{\"ev\":\"window\",\"shown\":%s}\n", shown ? "true" : "false");
	pthread_mutex_lock(&control_lock);
	for (int i = 0; i < connection_count; i++)
		(void)write(connections[i], line, n);
	pthread_mutex_unlock(&control_lock);
}

static bool hold_connection(int c)
{
	pthread_mutex_lock(&control_lock);
	bool room = connection_count < CONTROL_MAX;
	if (room) connections[connection_count++] = c;
	pthread_mutex_unlock(&control_lock);
	return room;
}

static void drop_connection(int c)
{
	pthread_mutex_lock(&control_lock);
	for (int i = 0; i < connection_count; i++)
		if (connections[i] == c) {
			connections[i] = connections[--connection_count];
			break;
		}
	pthread_mutex_unlock(&control_lock);
}

/// Reads the number given for `name` on this line, or returns `fallback`.
static int line_int(const char *line, const char *name, int fallback)
{
	char key[32];
	snprintf(key, sizeof(key), "\"%s\"", name);
	const char *at = strstr(line, key);
	if (!at) return fallback;
	at = strchr(at + strlen(key), ':');
	if (!at) return fallback;
	return (int)strtol(at + 1, NULL, 10);
}

/// Whether `name` is given as true on this line.
static bool line_bool(const char *line, const char *name)
{
	char key[32];
	snprintf(key, sizeof(key), "\"%s\"", name);
	const char *at = strstr(line, key);
	if (!at) return false;
	at = strchr(at + strlen(key), ':');
	if (!at) return false;
	while (*at == ':' || *at == ' ' || *at == '\t') at++;
	return strncmp(at, "true", 4) == 0;
}

/// Copies the string given for `name` on this line. Undoes the two escapes a
/// path can carry.
static char *line_text(const char *line, const char *name)
{
	char key[32];
	snprintf(key, sizeof(key), "\"%s\"", name);
	const char *at = strstr(line, key);
	if (!at) return NULL;
	at = strchr(at + strlen(key), ':');
	if (!at) return NULL;
	while (*at == ':' || *at == ' ' || *at == '\t') at++;
	if (*at != '"') return NULL;
	at++;

	char *out = (char *)malloc(strlen(at) + 1);
	if (!out) return NULL;
	char *w = out;
	while (*at && *at != '"') {
		if (*at == '\\' && (at[1] == '"' || at[1] == '\\')) at++;
		*w++ = *at++;
	}
	*w = '\0';
	if (*at != '"') { free(out); return NULL; }		// unterminated
	return out;
}

static void count_watcher(int by)
{
	pthread_mutex_lock(&control_lock);
	watchers += by;
	if (watchers < 0) watchers = 0;
	pthread_mutex_unlock(&control_lock);
	// A new watcher needs a whole screen. An idle guest draws nothing for
	// minutes at a time.
	queue_op(by > 0 ? CONTROL_WATCH : CONTROL_UNWATCH);
}

/// Records a frame that went by unpublished. The next copy carries the whole
/// screen.
void miss_shared_frame_osx()
{
	shared_frame_stale = true;
}

bool shared_frame_wanted_osx()
{
	pthread_mutex_lock(&control_lock);
	bool any = watchers > 0;
	pthread_mutex_unlock(&control_lock);
	return any;
}

int control_clients_osx()
{
	pthread_mutex_lock(&control_lock);
	int n = connection_count;
	pthread_mutex_unlock(&control_lock);
	return n;
}

/// Serves one connection until it closes. A `watch` lasts as long as the
/// connection.
static void *connection_thread(void *given)
{
	int c = (int)(intptr_t)given;
	if (!hold_connection(c)) { close(c); return NULL; }
	// Announce the surface before the client asks for anything.
	announce_surface(c);

	bool watching = false;
	char buf[1024];
	size_t held = 0;
	ssize_t got;
	while ((got = read(c, buf + held, sizeof(buf) - held - 1)) > 0) {
		held += got;
		buf[held] = '\0';
		char *line = buf, *end;
		while ((end = strchr(line, '\n')) != NULL) {
			*end = '\0';
			if      (line_says(line, "show"))  queue_op(CONTROL_SHOW);
			else if (line_says(line, "hide"))  queue_op(CONTROL_HIDE);
			else if (line_says(line, "quit"))  queue_op(CONTROL_QUIT);
			else if (line_says(line, "power")) queue_op(CONTROL_POWER);
			else if (line_says(line, "key")) {
				control_op op = { CONTROL_KEY, line_int(line, "code", -1), 0,
								  line_bool(line, "down") };
				if (op.a >= 0 && op.a < 128) queue_control(op);
			}
			else if (line_says(line, "mouse")) {
				control_op op = { CONTROL_MOUSE, line_int(line, "x", 0),
								  line_int(line, "y", 0), false };
				queue_control(op);
			}
			else if (line_says(line, "click")) {
				control_op op = { CONTROL_CLICK, line_int(line, "button", 0), 0,
								  line_bool(line, "down") };
				queue_control(op);
			}
			else if (line_says(line, "release")) queue_op(CONTROL_RELEASE);
			else if (line_says(line, "cdrom")) {
				control_op op = { CONTROL_CDROM, 0, 0, false, line_text(line, "path") };
				if (op.text) queue_control(op);
			}
			else if (line_says(line, "watch")   && !watching) { watching = true;  count_watcher(1); }
			else if (line_says(line, "unwatch") &&  watching) { watching = false; count_watcher(-1); }
			line = end + 1;
		}
		held = strlen(line);
		memmove(buf, line, held + 1);
	}
	// Release every key and button this connection holds down. A reader that
	// dies mid-chord leaves the guest holding Command.
	queue_op(CONTROL_RELEASE);
	if (watching) count_watcher(-1);
	drop_connection(c);
	close(c);
	return NULL;
}

/// Accepts connections, one thread each. A reader holds its connection open
/// for as long as it draws.
static void *control_thread(void *)
{
	for (;;) {
		int c = accept(control_socket, NULL, NULL);
		if (c < 0) {
			if (errno == EINTR) continue;
			return NULL;			// close_control_osx has closed it
		}
		pthread_t t;
		if (pthread_create(&t, NULL, connection_thread, (void *)(intptr_t)c) != 0)
			close(c);
		else
			pthread_detach(t);
	}
}

void close_control_osx()
{
	if (control_socket >= 0) { close(control_socket); control_socket = -1; }
	if (control_path[0]) { unlink(control_path); control_path[0] = '\0'; }
}

bool control_open_osx()
{
	return control_socket >= 0;
}

bool open_control_osx(const char *path)
{
	close_control_osx();

	struct sockaddr_un sa;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof(sa.sun_path)) {
		printf("WARNING: control socket path is too long: %s\n", path);
		return false;
	}
	strlcpy(sa.sun_path, path, sizeof(sa.sun_path));

	// Remove a socket path left behind by a machine that was killed.
	unlink(path);
	control_socket = socket(AF_UNIX, SOCK_STREAM, 0);
	if (control_socket < 0 ||
		bind(control_socket, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
		listen(control_socket, 4) < 0) {
		printf("WARNING: could not open the control socket at %s\n", path);
		close_control_osx();
		return false;
	}
	strlcpy(control_path, path, sizeof(control_path));

	// Writing to a socket whose reader has gone raises SIGPIPE and kills the
	// emulator.
	signal(SIGPIPE, SIG_IGN);

	pthread_t t;
	pthread_create(&t, NULL, control_thread, NULL);
	pthread_detach(t);
	return true;
}

// ---- the window, and the Dock --------------------------------------------

static id activity_token = nil;
static bool window_visible = true;
static bool nap_allowed = false;

/// Holds or drops the App Nap refusal. macOS throttles a process with nothing
/// on screen: the refusal holds while there is a window or a watcher.
static void update_activity()
{
	bool busy = window_visible || shared_frame_wanted_osx() || !nap_allowed;
	if (busy && activity_token == nil) {
		activity_token = [[NSProcessInfo processInfo]
			beginActivityWithOptions:NSActivityUserInitiated
							  reason:@"emulating a Macintosh"];
		[activity_token retain];
	} else if (!busy && activity_token != nil) {
		[[NSProcessInfo processInfo] endActivity:activity_token];
		[activity_token release];
		activity_token = nil;
	}
}

/// Updates the refusal on the main thread, as NSProcessInfo and NSApp require.
/// Call from any thread.
void activity_changed_osx()
{
	dispatch_async(dispatch_get_main_queue(), ^{ update_activity(); });
}

void allow_nap_osx(bool allowed)
{
	nap_allowed = allowed;
	activity_changed_osx();
}

/// Shows or hides the Dock icon and the Cmd-Tab entry. A machine with no
/// window on screen appears in neither.
static void set_dock_visible(bool visible)
{
	[NSApp setActivationPolicy:visible ? NSApplicationActivationPolicyRegular
									   : NSApplicationActivationPolicyAccessory];
	bool changed = window_visible != visible;
	window_visible = visible;
	update_activity();
	if (changed) announce_window(visible);
}

/// Shows or hides the window on the main thread. AppKit and SDL's window calls
/// crash the emulator from any other thread, and the redraw thread calls this.
void show_window_osx(SDL_Window *window, bool visible)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (visible) {
			set_dock_visible(true);
			SDL_ShowWindow(window);
			SDL_RaiseWindow(window);
			[NSApp activateIgnoringOtherApps:YES];
		} else {
			SDL_HideWindow(window);
			set_dock_visible(false);
		}
	});
}

/// Sets the activation policy before there is a window. The main thread calls
/// this from the video mode setup.
void start_hidden_osx()
{
	set_dock_visible(false);
}

void publish_shared_frame_osx(int width, int height, uint32_t format,
							  const void *pixels, int pitch,
							  int x, int y, int w, int h)
{
	if (!shared_frame) return;
	const size_t full_w = IOSurfaceGetWidth(shared_frame);
	const size_t full_h = IOSurfaceGetHeight(shared_frame);
	if ((size_t)width != full_w || (size_t)height != full_h) return;

	if (shared_frame_stale) { x = 0; y = 0; w = width; h = height; }
	if (w <= 0 || h <= 0) return;

	if (IOSurfaceLock(shared_frame, 0, NULL) != kIOReturnSuccess) return;
	const int stride = (int)IOSurfaceGetBytesPerRow(shared_frame);
	// Both sides hold 4 bytes a pixel. The source is the host surface, in the
	// texture's own 32-bit format.
	SDL_ConvertPixels(w, h, format,
					  (const uint8_t *)pixels + (size_t)y * pitch + (size_t)x * 4, pitch,
					  SDL_PIXELFORMAT_ARGB8888,
					  (uint8_t *)IOSurfaceGetBaseAddress(shared_frame)
						  + (size_t)y * stride + (size_t)x * 4, stride);
	IOSurfaceUnlock(shared_frame, 0, NULL);
	shared_frame_stale = false;
}

#if SDL_VERSION_ATLEAST(2, 0, 0)
#include <Metal/Metal.h>

bool MetalIsAvailable() {
	const int EL_CAPITAN = 15; // Darwin major version of El Capitan
	char s[16];
	size_t size = sizeof(s);
	int v;
	if (sysctlbyname("kern.osrelease", s, &size, NULL, 0) || sscanf(s, "%d", &v) != 1 || v < EL_CAPITAN) return false;
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	bool r = dev != nil;
	[dev release];
	return r;
}

void disable_SDL2_macosx_menu_bar_keyboard_shortcuts() {
	for (NSMenuItem * menu_item in [NSApp mainMenu].itemArray) {
		if (menu_item.hasSubmenu) {
			for (NSMenuItem * sub_item in menu_item.submenu.itemArray) {
				sub_item.keyEquivalent = @"";
				sub_item.keyEquivalentModifierMask = 0;
			}
		}
		if ([menu_item.title isEqualToString:@"View"]) {
			[[NSApp mainMenu] removeItem:menu_item];
			break;
		}
	}
}

static NSWindow *get_nswindow(SDL_Window *window) {
#if SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_PropertiesID props = SDL_GetWindowProperties(window);
	return (NSWindow *)SDL_GetPointerProperty(props, "SDL.window.cocoa.window", NULL);
#else
	SDL_SysWMinfo wmInfo;
	SDL_VERSION(&wmInfo.version);
	return SDL_GetWindowWMInfo(window, &wmInfo) ? wmInfo.info.cocoa.window : nil;
#endif
}

bool is_fullscreen_osx(SDL_Window * window)
{
	if (!window) {
		return false;
	}
	
	const NSWindowStyleMask styleMask = [get_nswindow(window) styleMask];
	return (styleMask & NSWindowStyleMaskFullScreen) != 0;
}

#endif // SDL_VERSION_ATLEAST(2, 0, 0)

#if SDL_VERSION_ATLEAST(3, 0, 0) && defined(VIDEO_CHROMAKEY)

// from https://github.com/zydeco/macemu/tree/rootless/

void make_window_transparent(SDL_Window *window)
{
	if (!window) {
		return;
	}
	NSWindow *cocoaWindow = get_nswindow(window);
	static bool observing;
    if (!observing) {
		cocoaWindow.level = NSMainMenuWindowLevel + 1;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:cocoaWindow queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            NSWindow *window = (NSWindow *)note.object;
            window.level = NSMainMenuWindowLevel + 1;
        }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:cocoaWindow queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            NSWindow *window = (NSWindow *)note.object;
            // hack for window to be sent behind new key window
            [window setIsVisible:NO];
            [window setLevel:NSNormalWindowLevel];
            [window setIsVisible:YES];
        }];
        observing = true;
    }
}

void set_mouse_ignore(SDL_Window *window, int flag) {
	if (!window) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		get_nswindow(window).ignoresMouseEvents = flag;
	});
}

#endif // SDL_VERSION_ATLEAST(3, 0, 0) && defined(VIDEO_CHROMAKEY)

void set_menu_bar_visible_osx(bool visible)
{
	[NSMenu setMenuBarVisible:(visible ? YES : NO)];
}

void set_current_directory()
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	chdir([[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] UTF8String]);
	[pool release];
}
