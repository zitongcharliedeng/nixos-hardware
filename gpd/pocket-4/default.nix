{ lib, pkgs, ... }:
let
  inherit (lib) mkIf mkDefault;
in
{
  imports = [
    ../../common/pc/laptop
    ../../common/pc/ssd
    ../../common/cpu/amd
    ../../common/cpu/amd/pstate.nix
    ../../common/gpu/amd
    ../../common/hidpi.nix
  ];

  boot = {
    # As of kernel version 6.6.72, amdgpu throws a fatal error during init, resulting in a barely-working display
    kernelPackages = mkIf (lib.versionOlder pkgs.linux.version "6.12") pkgs.linuxPackages_latest;

    kernelParams = [
      # The GPD Pocket 4 uses a tablet LTPS display, that is mounted rotated 90° counter-clockwise
      "fbcon=rotate:1"
      "video=eDP-1:panel_orientation=right_side_up"
      # Cap PCIe at Gen 3. The eGPU negotiates Gen 4 x4 at boot by default,
      # fails to train the link on the AMD 890M, and hangs. Bit layout:
      # 0x40000 = only Gen 3 capability advertised (Gen 4+ masked off).
      "amdgpu.pcie_gen_cap=0x40000"
    ];
  };

  # i2c-hid runtime PM workaround: the HAILUCK keyboard and i2c touchscreen
  # drop key/touch events after the I2C controller suspends. i2c-designware
  # (since kernel 3.13) enables runtime PM aggressively, and i2c-hid firmware
  # designed for Windows-style always-on buses misses interrupt edges when
  # the controller sleeps. Force power/control=on for every i2c_hid_acpi
  # device via udev (covers hotplug + resume) plus a boot-time sweep for
  # already-bound devices.
  #
  # Proper upstream fix: kernel patch to i2c-hid-core.c keeping the parent
  # I2C adapter awake while any HID device is open. Until that lands, this
  # workaround mirrors what Framework laptop modules ship inline here.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="hid", SUBSYSTEMS=="i2c", DRIVERS=="i2c_hid_acpi", ATTR{power/control}="on"
    ACTION=="add|change", SUBSYSTEM=="i2c", DRIVERS=="i2c_hid_acpi", ATTR{power/control}="on"
  '';

  systemd.services.gpd-pocket-4-i2c-hid-keep-alive = {
    description = "Keep i2c-hid buses awake so keyboard/touchscreen keys survive idle (GPD Pocket 4)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for dev in /sys/bus/i2c/drivers/i2c_hid_acpi/*/power/control; do
        [ -w "$dev" ] && echo on > "$dev" || true
      done
      for dev in /sys/bus/hid/drivers/hid-generic/*/power/control \
                 /sys/bus/hid/drivers/hid-multitouch/*/power/control; do
        [ -w "$dev" ] && echo on > "$dev" || true
      done
    '';
  };

  # Turn on IIO for accelerometer screen rotation.
  hardware.sensor.iio.enable = lib.mkDefault true;

  # Novatek NVTK0603 touchscreen (HID 0603:F001) coordinate-space rotation.
  # The display is physically mounted rotated 90° counter-clockwise
  # (video=eDP-1:panel_orientation=right_side_up), but the touchscreen
  # reports coordinates in the panel's native (unrotated) frame. Result:
  # taps land at screen-rotated offsets, so touch feels broken.
  #
  # The libinput calibration matrix remaps ABS_X/ABS_Y to match the 90° CCW
  # display rotation. Matrix "0 -1 1 1 0 0" = rotate_left.
  #
  # This is a udev hwdb entry scoped to the GPD Pocket 4 DMI string so it
  # is inert on any other machine.
  # Match via HID modalias (bus/vendor/product) instead of device name.
  # The earlier form used the input name "NVTK0603:00 0603:F001", but the
  # embedded colons are interpreted as hwdb field separators and the rule
  # never matched. The modalias form has no user-authored colons.
  # DMI match scopes the rule to the Pocket 4.
  # Evdev modalias for this device: input:b0018v0603pF001e0100-*
  # (Note: v0603 and pF001 with no zero-padding — differs from HID modalias
  # which uses p0000F001.) DMI scopes to GPD G1628-04.
  services.udev.extraHwdb = ''
    evdev:input:b0018v0603pF001*:dmi:*svnGPD:pnG1628-04*
     LIBINPUT_CALIBRATION_MATRIX=0 -1 1 1 0 0
  '';

  fonts.fontconfig = {
    subpixel.rgba = "vbgr"; # Pixel order for rotated screen

    # The display has √(2560² + 1600²) px / 8.8in ≃ 343 dpi
    # Per the documentation, antialiasing, hinting, etc. have no visible effect at such high pixel densities anyhow.
    hinting.enable = mkDefault false;
  };

  # More HiDPI settings
  services.xserver.dpi = 343;
}
