--[[
  Copyright 2016 Stefano Mazzucco

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]

--[[--
  Control audio devices using the
  [PulseAudio DBus interface](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/).

  For this to work, you need the line
  `load-module module-dbus-protocol`
  in the `/etc/pulse/default.pa` configuration file.

  @license Apache License, version 2.0
  @author Stefano Mazzucco <stefano AT curso DOT re>
  @copyright 2016 Stefano Mazzucco
]]

local ldbus = require("ldbus_api")

local pulse = {}

--- Get the PulseAudio DBus address
-- @return a string representing the PulseAudio
-- [DBus address](https://dbus.freedesktop.org/doc/dbus-tutorial.html#addresses).
function pulse.get_address()
	local opts = {
		bus = "session",
		dest = "org.PulseAudio1",
		interface = "org.freedesktop.DBus.Properties",
		method = "Get",
		path = "/org/pulseaudio/server_lookup1",
		args = {
			{
				sig = ldbus.types.string,
				value = "org.PulseAudio.ServerLookup1"
			},
			{
				sig = ldbus.types.string,
				value = "Address"
			}
		}
	}
	local data = ldbus.api.call(opts)
	return ldbus.api.get_value(data[1])
end

local function invalid_address_error(address, errormsg)
	local msg = "Cannot connect to PulseAudio DBus address '" ..
		address ..
		"' have you added the line\n" ..
		"load-module module-dbus-protocol\n" ..
		"to your configuration? " ..
		"(e.g. /etc/pulse/default.pa)\n" ..
		"Original error:\n" ..
		errormsg
	error(msg, 2)
end

local function get_property(address, path, interface, member)
	local opts = {
		bus = address,
		dest = "org.PulseAudio1",
		interface = "org.freedesktop.DBus.Properties",
		method = "Get",
		path = path,
		args = {
			{
				sig = ldbus.types.string,
				value = interface
			},
			{
				sig = ldbus.types.string,
				value = member
			}
		}
	}
	local status, data = pcall(ldbus.api.call, opts)
	if status then
		return ldbus.api.get_value(data)[1]
	end
	invalid_address_error(address, data)
end

local function set_property(address, path, interface, member, value)
	local opts = {
		bus = address,
		dest = "org.PulseAudio1",
		interface = "org.freedesktop.DBus.Properties",
		method = "Set",
		path = path,
		args = {
			{
				sig = ldbus.types.string,
				value = interface
			},
			{
				sig = ldbus.types.string,
				value = member
			},
			value
		}
	}
	ldbus.api.call(opts)
end

--- Get the avaialble PulseAudio sinks
-- @param address The address to the PulseAudio socket
-- @return an array of strings representing the DBus object path
-- to the first PulseAudio sink (e.g. `/org/pulseaudio/core1/sink0`)
function pulse.get_sinks(address)
	return get_property(address, "/org/pulseaudio/core1", "org.PulseAudio.Core1", "Sinks")
end

local function get_base_volume(address, sink)
	return get_property(address, sink, "org.PulseAudio.Core1.Device", "BaseVolume")
end

local function get_active_port(address, sink)
	return get_property(address, sink, "org.PulseAudio.Core1.Device", "ActivePort")
end

local function get_volume(address, sink)
	return get_property(address, sink, "org.PulseAudio.Core1.Device", "Volume")
end

local function get_volume_percent(address, sink)
	local base_volume = get_base_volume(address, sink)
	local volume = get_volume(address, sink)

	local volume_percent = {}
	for i, v in ipairs(volume) do
		volume_percent[i] = math.ceil(v / base_volume * 100)
	end

	return volume_percent
end

local function is_muted(address, sink)
	return get_property(address, sink, "org.PulseAudio.Core1.Device", "Mute")
end

local function set_muted(address, sink, value)
	set_property(address, sink, "org.PulseAudio.Core1.Device", "Mute",
							 {sig = ldbus.types.variant,
								value = {sig = ldbus.types.boolean,
												 value = value}
	})
end

local function toggle_muted(address, sink)
	local muted = is_muted(address, sink)
	set_muted(address, sink, not muted)
end

local function set_volume(address, sink, value)
	set_property(address, sink, "org.PulseAudio.Core1.Device", "Volume",
							 {sig = ldbus.types.variant,
								value = {sig = ldbus.types.array .. ldbus.types.uint32,
												 value = value}
	})
end

local function set_volume_percent(address, sink, percent)
	local base_volume = get_base_volume(address, sink)
	local volume = {}
	for i, v in ipairs(percent) do
		volume[i] = v * base_volume / 100
	end
	set_volume(address, sink, volume)
end

--- Ask the PulseAudio server to send the given signal from the given interface.
-- If this function is called more than once for the same signal, the latest
-- call always replaces the previous object list.
-- In order to support clients that want to receive absolutely all signals,
-- **both** the `interface` and the `signal` parameters must be set to `nil`
-- or left unspecified.
-- In that case all previous signal filters are discarded.
-- @param address The [DBus address](https://dbus.freedesktop.org/doc/dbus-tutorial.html#addresses).
-- @param[optional] interface The name of the interface. E.g. `"org.PulseAudio.Core1.Device"`.
-- @param[optional] signal The signal name. E.g. `"VolumeUpdated"`.
-- @param[optional] object_paths Array of object paths that we want to listen to.
-- If empty or not specified, signals from all objects are sent.
function pulse.listen_for_signal(address, interface, signal, object_paths)
	local iface_and_signal = ""
	if interface and signal then
		iface_and_signal = interface .. "." .. signal
	end
	local opts = {
		bus = address,
		dest = "org.PulseAudio1",
		interface = "org.PulseAudio.Core1",
		method = "ListenForSignal",
		path = "/org/pulseaudio/core1",
		args = {
			{
				sig = ldbus.types.string,
				value = iface_and_signal
			},
			{
				sig = ldbus.types.array .. ldbus.types.object_path,
				value = object_paths or {}
			}
		}
	}
	ldbus.api.call(opts)
end

local getters = {
	active_port = get_active_port,
	volume = get_volume_percent,
	muted = is_muted
}

local setters = {
	volume = set_volume_percent,
	muted = set_muted
}

local meta = {
	__index = function (tbl, key)
		local f = getters[key]
		if f then
			return f(tbl.address, tbl.path)
		else
			rawget(tbl, key)
		end
	end,
	__newindex = function (tbl, key, value)
		local f = setters[key]
		if f then
			f(tbl.address, tbl.path, value)
		else
			error("Cannot set key (" .. key .. ") to value (" .. tostring(value) .. ")", 2)
		end
	end
}

pulse.Sink = {}

--- Toggle the muted state and return it
-- @return The muted state after toggling
function pulse.Sink:toggle_muted()
	toggle_muted(self.address, self.path)
	return self.muted
end

--- Step up the volume by an amount equal to `self.volume_step`.
-- Calling this function will never set the volume above `self.volume_max`.
function pulse.Sink:volume_up()
	local volume = self.volume
	local up
	for i, v in ipairs(volume) do
		up = v + self.volume_step
		if up > self.volume_max then
			volume[i] = self.volume_max
		else
			volume[i] = up
		end
	end
	self.volume = volume
end

--- Step down the volume by an amount equal to `self.volume_step`.
-- Calling this function will never set the volume below zero (which is,
-- by the way, an error).
function pulse.Sink:volume_down()
	local volume = self.volume
	local down
	for i, v in ipairs(volume) do
		down = v - self.volume_step
		if down >= 0 then
			volume[i] = down
		else
			volume[i] = 0
		end
	end
	self.volume = volume
end

--- Create a new Sink object with the following properties:
--
-->`volume`: the volume percentage in each channel as an array of ints.
-->When set, you can use a 1-element array and that will set the same
-->volume to all channels (e.g. `sink.volume = {42}`).
--
-->`volume_step`: the volume step in percentage
--
-->`volume_max`: the maximum volume in percentage
--
-->`muted`: whether the sink is muted
--
-- Setting a property will be reflected on the PulseAudio sink.
-- Trying to set other properties will result in an error.
-- @param bus The PulseAudio address as a string
-- @param path The sink object path as a string
-- @param[opt] volume_step The volume step in % (defaults to 5)
-- @param[opt] volume_max The maximum volume in % (defaults to 150)
-- @return A new Sink object
-- @see pulse.get_address
-- @see pulse.get_sinks
function pulse.Sink:new(bus, path, volume_step, volume_max)
	local o = {
		address = bus,
		path = path,
		volume_step = volume_step or 5,
		volume_max = volume_max or 150,
		toggle_muted = self.toggle_muted,
		volume_up = self.volume_up,
		volume_down = self.volume_down
	}
	setmetatable(o, meta)
	return o
end

setmetatable(pulse.Sink, meta)

return pulse
