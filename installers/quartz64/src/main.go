// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Talos overlay installer for the Pine64 RK3566 family.
//
// One source, one binary per board: the board name is set at link time with
//
//	go build -ldflags "-X main.board=quartz64-a"
//
// and must match the overlay name passed to the imager (--overlay-name).
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/siderolabs/go-copy/copy"
	"github.com/siderolabs/talos/pkg/machinery/overlay"
	"github.com/siderolabs/talos/pkg/machinery/overlay/adapter"
	"golang.org/x/sys/unix"
)

// Rockchip boot ROM looks for the idbloader at sector 64.
const off int64 = 512 * 64

// board is injected with -ldflags "-X main.board=<name>".
var board = ""

// dtbs maps overlay/board name -> device tree path (relative to arm64/dtb and
// to the ESP's /dtb directory). These names match U-Boot's
// CONFIG_DEFAULT_FDT_FILE for each <board>-rk3566_defconfig, which is what
// U-Boot's EFI boot path loads from the ESP.
var dtbs = map[string]string{
	"quartz64-a":       "rockchip/rk3566-quartz64-a.dtb",
	"quartz64-b":       "rockchip/rk3566-quartz64-b.dtb",
	"soquartz-blade":   "rockchip/rk3566-soquartz-blade.dtb",
	"soquartz-model-a": "rockchip/rk3566-soquartz-model-a.dtb",
	"soquartz-cm4":     "rockchip/rk3566-soquartz-cm4.dtb",
}

func main() {
	if _, ok := dtbs[board]; !ok {
		fmt.Fprintf(os.Stderr, "installer built for unknown board %q\n", board)
		os.Exit(1)
	}

	adapter.Execute(&quartz64{})
}

type quartz64 struct{}

type quartz64ExtraOptions struct{}

func (i *quartz64) GetOptions(extra quartz64ExtraOptions) (overlay.Options, error) {
	return overlay.Options{
		Name: board,
		KernelArgs: []string{
			// HDMI (if the kernel drives it) + the UART2 debug header at 1.5 Mbaud.
			// The last console= is /dev/console, so Talos logs go to serial.
			"console=tty0",
			"console=ttyS2,1500000n8",
			"sysctl.kernel.kexec_load_disabled=1",
		},
		PartitionOptions: overlay.PartitionOptions{
			// Leave the first 10 MiB for idbloader + u-boot.itb.
			Offset: 2048 * 10,
		},
	}, nil
}

func (i *quartz64) Install(options overlay.InstallOptions[quartz64ExtraOptions]) error {
	f, err := os.OpenFile(options.InstallDisk, os.O_RDWR|unix.O_CLOEXEC, 0o666)
	if err != nil {
		return fmt.Errorf("failed to open %s: %w", options.InstallDisk, err)
	}

	defer f.Close() //nolint:errcheck

	uboot, err := os.ReadFile(filepath.Join(options.ArtifactsPath, "arm64/u-boot", board, "u-boot-rockchip.bin"))
	if err != nil {
		return err
	}

	if _, err = f.WriteAt(uboot, off); err != nil {
		return err
	}

	// NB: In the case that the block device is a loopback device, we sync here
	// to ensure that the file is written before the loopback device is
	// unmounted.
	if err = f.Sync(); err != nil {
		return err
	}

	dtb := dtbs[board]
	src := filepath.Join(options.ArtifactsPath, "arm64/dtb", dtb)
	dst := filepath.Join(options.MountPrefix, "/boot/EFI/dtb", dtb)

	if err = os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}

	return copy.File(src, dst)
}
