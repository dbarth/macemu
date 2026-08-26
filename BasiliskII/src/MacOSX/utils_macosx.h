/*
 *	utils_macosx.h - Mac OS X utility functions.
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

#ifndef UTILS_MACOSX_H
#define UTILS_MACOSX_H

#ifdef USE_SDL
#if SDL_VERSION_ATLEAST(2,0,0)
void disable_SDL2_macosx_menu_bar_keyboard_shortcuts();
bool is_fullscreen_osx(SDL_Window * window);
#endif
#endif

void set_menu_bar_visible_osx(bool visible);

void set_current_directory();

bool MetalIsAvailable();

// Command kinds on the control socket. The SDL thread drains the queue.
enum {
	CONTROL_NONE = 0,
	CONTROL_SHOW,
	CONTROL_HIDE,
	CONTROL_QUIT,
	CONTROL_WATCH,
	CONTROL_UNWATCH,
	CONTROL_POWER,
	CONTROL_KEY,		// a: ADB key code, down
	CONTROL_MOUSE,		// a, b: where, in the guest's own pixels
	CONTROL_CLICK,		// a: button, down
	CONTROL_RELEASE,	// releases every key and button this socket holds
	CONTROL_CDROM,		// text: the disc image to put in the drive
};

/// `a` and `b` are the code or the position, depending on `what`.
struct control_op {
	int what;
	int a, b;
	bool down;
	/// The caller that takes the op off the queue frees this.
	char *text;
};
typedef struct control_op control_op;

// Open a unix socket taking one line of JSON per command: {"op":"show"}.
bool open_control_osx(const char *path);
bool control_open_osx();
void close_control_osx();
bool next_control_op_osx(control_op *op);

// Whether a client has asked for frames with `watch`. Nothing is copied
// into the surface while none has.
bool shared_frame_wanted_osx();

// How many clients are on the control socket, watching or not. The close
// widget hides the window while there is one.
int control_clients_osx();
void miss_shared_frame_osx();

// Whether macOS may throttle this machine. The refusal holds while there is
// a window on screen or a watcher.
void allow_nap_osx(bool allowed);
void activity_changed_osx();

// Put the window and the Dock icon on screen or take them off. Call from
// any thread; the work runs on the main one.
void show_window_osx(SDL_Window *window, bool visible);
void start_hidden_osx();

// Publish the guest's screen into an IOSurface for another process to draw.
// The control socket carries the surface's id as an event.
bool open_shared_frame_osx(int width, int height);
void close_shared_frame_osx();
void publish_shared_frame_osx(int width, int height, uint32_t format,
							  const void *pixels, int pitch,
							  int x, int y, int w, int h);

#endif
