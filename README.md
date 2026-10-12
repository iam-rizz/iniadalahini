# lxc-iolimit

Limit IO disk (bandwidth read & write) **per plan** untuk container LXC di **Proxmox VE + Virtualizor**, memakai cgroup v2 `io.max`.

Proxmox tidak menyediakan limit IO untuk LXC dari GUI. `lxc-iolimit` menambahkan limit tersebut secara otomatis: VPS baru langsung mendapat limit sesuai plan, limit ikut berubah saat upgrade/downgrade plan, dan terpasang ulang setiap kali container start.

## Fitur

- Limit read/write (MB/s) per plan Virtualizor, dikonfigurasi di satu file.
- Otomatis saat VPS dibuat, diedit, di-upgrade/downgrade, di-unsuspend, dan dihapus.
- Upgrade/downgrade plan berlaku langsung **tanpa reboot**.
- Terpasang ulang di **setiap start** container, apa pun pemicunya: panel Virtualizor, GUI Proxmox, `pct`, `reboot` dari dalam CT, atau node reboot.
- Device disk dicari dinamis per container (major:minor tidak di-hardcode).
- CLI `lxc-iolimit` untuk cek status, set limit manual, dan apply ulang.
- Installer satu file dengan backup dan cek syntax otomatis untuk `filter.php`.

## Cara kerja

```
Virtualizor (filter.php)                      LXC (setiap container start)
  after_createvps / editvs / unsuspend          lxc.hook.start-host (global)
            │                                             │
            ▼                                             ▼
  /etc/lxc-iolimit/ct.map  ◄────── dibaca ──────  lxc-iolimit apply <ctid>
  (1017=plan:2)                                           │
            │                                             ▼
            └── CT running? apply langsung ───►  /sys/fs/cgroup/lxc/<ctid>/io.max
                                                 252:16 rbps=209715200 wbps=209715200
```

1. **Virtualizor** mencatat plan tiap CT ke `ct.map` lewat filter `after_createvps`, `editvs`, dan `unsuspendvps`. Kalau CT sedang running, limit langsung diterapkan.
2. **Hook LXC global** (`/usr/share/lxc/config/common.conf.d/99-lxc-iolimit.conf`) menjalankan `lxc-iolimit apply` setiap kali container start. Hook ini dimuat oleh semua CT dan tidak tersentuh oleh Virtualizor saat menulis ulang config CT.
3. `lxc-iolimit apply` membaca plan CT dari `ct.map`, mengambil limit MB/s dari `plans.conf`, mencari device rootfs CT, lalu menulis ke `io.max`.

## Requirement

- Proxmox VE dengan cgroup v2 (default sejak PVE 7).
- Virtualizor dengan virtualisasi **Proxmox LXC** (`proxl`).
- Rootfs CT berada di storage block device (**LVM / LVM-thin**). Storage berbasis directory/file belum didukung.
- Dijalankan sebagai root di node Proxmox (node tempat CT berjalan).

## Instalasi

```bash
git clone https://github.com/<username>/lxc-iolimit.git
cd lxc-iolimit
bash install.sh
```

Installer akan:

1. Mengecek Proxmox, cgroup v2, dan controller `io`.
2. Membuat config `/etc/lxc-iolimit/plans.conf` (kalau belum ada).
3. Memasang CLI di `/usr/local/lxc-iolimit/` dan `/usr/local/bin/lxc-iolimit`.
4. Memasang hook LXC global.
5. Membuat `filter.php` dari `filter.txt` (kalau belum ada), lalu menambahkan blok include di antara marker `lxc-iolimit BEGIN/END`. Backup otomatis dibuat sebagai `filter.php.bak-<timestamp>`, dan file dikembalikan otomatis kalau `php -l` gagal.
6. Menerapkan limit ke semua CT yang sedang running.

Installer aman dijalankan ulang untuk update. `plans.conf` dan `ct.map` yang sudah ada tidak ditimpa.

## Konfigurasi plan

Edit `/etc/lxc-iolimit/plans.conf`:

```ini
# <plan_id>=<MB/s>   (0 = tanpa limit)
default=100
1=100
2=200
```

- **Plan ID** bisa dilihat di Virtualizor: *Plans → List Plans* (kolom ID).
- `default` dipakai untuk CT yang belum tercatat di `ct.map` (misalnya CT yang dibuat di luar Virtualizor) dan untuk plan yang tidak terdaftar.

Setelah mengubah `plans.conf`, terapkan ke CT yang sedang running:

```bash
lxc-iolimit apply-all
```

Karena `ct.map` menyimpan plan ID (bukan angka limit), perubahan di `plans.conf` otomatis berlaku untuk semua CT di plan tersebut.

## CLI

```
lxc-iolimit status              Tampilkan limit semua CT yang running
lxc-iolimit apply <ctid>        Terapkan limit ke CT
lxc-iolimit apply-all           Terapkan limit ke semua CT yang running
lxc-iolimit plan <ctid> <plid>  Set CT memakai limit plan tertentu
lxc-iolimit set <ctid> <MB/s>   Set limit manual untuk CT (0 = tanpa limit)
lxc-iolimit unset <ctid>        Hapus CT dari ct.map (kembali ke default)
lxc-iolimit clear <ctid>        Lepas limit sementara (sampai CT start lagi)
lxc-iolimit clear-all           Lepas limit semua CT yang running
```

Contoh output `status`:

```
CT      SUMBER     LIMIT          IO.MAX
1015    plan:1     100 MB/s       252:13 rbps=104857600 wbps=104857600 riops=max wiops=max
1016    plan:2     200 MB/s       252:15 rbps=209715200 wbps=209715200 riops=max wiops=max
1020    manual     50 MB/s        252:18 rbps=52428800 wbps=52428800 riops=max wiops=max
```

Limit manual (`set`) akan ditimpa kembali ke limit plan kalau VPS diedit atau di-unsuspend dari Virtualizor.

## Pengujian

Skenario berikut sudah diuji di Proxmox VE + Virtualizor (LXC Debian 12, storage LVM-thin):

| Skenario | Hasil |
|---|---|
| VPS baru (plan 1 / plan 2) | Limit 100 / 200 MB/s sesuai plan |
| `pct reboot`, reboot dari panel | Limit terpasang ulang |
| Upgrade plan 1 → 2 | Limit berubah tanpa reboot |
| Suspend / unsuspend | Limit tetap |
| fio sequential read (bs 1M, iodepth 16, direct) | Tertahan stabil di 100 MiB/s |

Tes manual dari dalam CT:

```bash
fio --name=read-test --filename=/root/fio-test --bs=1M --size=2G --rw=read \
    --direct=1 --ioengine=libaio --iodepth=16 --runtime=10 --time_based --group_reporting
fio --name=write-test --filename=/root/fio-test --bs=1M --size=2G --rw=write \
    --direct=1 --ioengine=libaio --iodepth=16 --runtime=10 --time_based --group_reporting
rm -f /root/fio-test
```

## Log

```bash
tail -f /var/log/lxc-iolimit.log
```

```
2026-10-12T13:00:44+07:00 CT 1017 plan 2
2026-10-12T13:00:45+07:00 CT 1017 252:16 rbps=209715200 wbps=209715200 OK
```

Log dirotasi mingguan lewat `/etc/logrotate.d/lxc-iolimit`.

## File yang dipasang

| Path | Fungsi |
|---|---|
| `/usr/local/lxc-iolimit/lxc-iolimit` | CLI dan logika apply limit |
| `/usr/local/lxc-iolimit/lxc-hook.sh` | Hook LXC `start-host` |
| `/usr/local/lxc-iolimit/virtualizor-filter.php` | Filter Virtualizor (di-include dari `filter.php`) |
| `/usr/share/lxc/config/common.conf.d/99-lxc-iolimit.conf` | Mendaftarkan hook LXC global |
| `/usr/local/virtualizor/hooks/filter.php` | Blok include di antara marker `lxc-iolimit` |
| `/etc/lxc-iolimit/plans.conf` | Limit MB/s per plan |
| `/etc/lxc-iolimit/ct.map` | Plan / limit per CT (dikelola otomatis) |
| `/var/log/lxc-iolimit.log` | Log |

## Migrasi dari setup manual

Kalau sebelumnya memakai setup manual (fungsi `iolimit_*` di `filter.php`, hookscript `local:snippets/iolimit.sh`, dan `/var/lib/vz/snippets/iolimit.map`):

1. Hapus dari `filter.php` semua fungsi `iolimit_plan_bps`, `iolimit_apply`, `iolimit_after_createvps`, `iolimit_editvs`, berikut baris `insert_filter(...)`-nya. Kembalikan juga isi `my_unsuspendvps()` ke bawaan (`return true;`).
2. Jalankan `bash install.sh`.

Installer akan otomatis:

- Memindahkan isi `iolimit.map` lama ke `ct.map` (sebagai limit manual MB/s; berubah jadi berbasis plan saat VPS diedit/unsuspend berikutnya, atau set dengan `lxc-iolimit plan <ctid> <plid>`).
- Melepas `hookscript: local:snippets/iolimit.sh` dari config semua CT.
- Menghapus hook global lama `99-iolimit.conf`.

Setelah itu file lama di `/var/lib/vz/snippets/` (`iolimit.sh`, `iolimit-lxc.sh`, `iolimit.map`) boleh dihapus.

## Uninstall

```bash
bash install.sh uninstall   # config di /etc/lxc-iolimit disimpan
bash install.sh purge       # hapus beserta config
```

Uninstall melepas limit dari CT yang running, menghapus hook LXC, menghapus blok `lxc-iolimit` dari `filter.php` (dengan backup), dan menghapus file aplikasi.

## Batasan dan catatan

- Limit hanya diterapkan pada **rootfs** CT. Mount point tambahan (`mp0`, `mp1`, ...) belum dibatasi.
- Hanya bandwidth (`rbps`/`wbps`) yang dibatasi. IOPS (`riops`/`wiops`) dibiarkan `max`.
- Untuk setup Virtualizor master-slave, jalankan installer di **setiap node** Proxmox.
- Upgrade resource lewat configurable options billing tanpa mengganti plan **tidak** mengubah limit, karena limit mengikuti plan ID.
- Hook LXC global berlaku untuk **semua** CT di node. CT yang tidak dikelola Virtualizor mendapat limit `default`. Set `default=0` kalau CT seperti itu tidak boleh dibatasi.

## Troubleshooting

**Limit tidak terpasang.** Cek log `/var/log/lxc-iolimit.log` lalu jalankan manual:

```bash
lxc-iolimit apply <ctid>
cat /sys/fs/cgroup/lxc/<ctid>/io.max
```

**`device rootfs tidak ditemukan`.** Rootfs CT tidak berada di block device (storage directory/file), atau `pvesm path` gagal untuk volume tersebut. Cek dengan:

```bash
grep ^rootfs: /etc/pve/lxc/<ctid>.conf
pvesm path <volume>
```

**Limit tidak berubah setelah ganti plan.** Pastikan blok `lxc-iolimit BEGIN/END` ada di `filter.php` dan syntax-nya valid:

```bash
grep -n "lxc-iolimit" /usr/local/virtualizor/hooks/filter.php
/usr/local/emps/bin/php -l /usr/local/virtualizor/hooks/filter.php
```

**Pesan `echo: write error: Invalid argument`.** Format nilai `io.max` tidak valid, biasanya karena limit kosong. Cek `plans.conf` dan entri CT di `ct.map`.
