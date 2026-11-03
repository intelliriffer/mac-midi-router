# Project Requirements

## Project Overview

A MIDI matrix router done in Swift for macOS: route input MIDI ports to
output MIDI ports, either a single channel or all channels from the input
port to the output port.

## It should

1. Allow routing a MIDI input port to multiple output ports.
2. Allow routing a single channel or all MIDI channels.
3. Handle disconnection and reconnection automatically.
4. Remember port names and do the mapping based on port names, so port-number
   reordering must not affect connections.
5. Remember port mappings and allow the user to save mapping presets, load a
   preset, and delete presets.
6. One MIDI input may also be routed to multiple ports.
7. A port should be able to accept input from multiple input ports (merged).
