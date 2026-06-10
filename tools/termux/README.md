# Frida en Termux (build nativo, Android arm64)

Estos scripts compilan Frida **de forma nativa dentro de Termux**, usando el
clang propio de Termux (Bionic), **sin NDK**. Esto es posible gracias a los
parches en `releng/` que detectan Termux y configuran la toolchain del
dispositivo en lugar de hacer cross-compile.

## Qué se construye

- `frida-server` — daemon principal
- `frida-gadget` — librería para preload
- `frida-inject` — inyección puntual de scripts
- `_frida` — binding de Python
- `frida`, `frida-ps`, `frida-trace`, `frida-ls-devices`, `frida-kill`,
  `frida-discover` — herramientas CLI (`frida-tools`)

## Requisitos

- Termux (probado en 0.119.x) en Android arm64 (probado en Android 16 / API 36).
- Espacio: varios GB. RAM: cuanta más mejor (el build de frida-core es pesado).
- Tiempo: el primer build puede tardar **horas** en el dispositivo.

Los scripts instalan automáticamente los paquetes de Termux que faltan
(`clang`, `python`, `glib`, `golang`, `nodejs-lts`, etc.).

## Uso

### Opción A — compilar e instalar directamente

```bash
git clone --recurse-submodules https://github.com/EduardoC3677/frida.git
cd frida
bash tools/termux/termux-build-install.sh --jobs $(nproc)
```

Opciones: `--clean` (borra `build/` antes), `--no-install` (solo compila),
`--prefix DIR` (prefijo alternativo).

### Opción B — generar un .deb e instalarlo

```bash
bash tools/termux/build-deb.sh --jobs $(nproc)
dpkg -i dist/frida_*_aarch64.deb
```

El `.deb` se genera para la arquitectura `aarch64` de Termux y al instalarlo
deja todas las herramientas en el prefijo de Termux automáticamente.

## Notas

- Si `frida-core` exige el fork de Vala de Frida y el `valac` de Termux no
  basta, el build lo indicará; en ese caso habrá que compilar ese componente
  aparte. El binding de Python y las herramientas CLI no lo necesitan.
- El build usa `--without-prebuilds=toolchain,sdk:build,sdk:host` para no
  descargar bundles glibc que no corren bajo Bionic: todo se compila de fuente.
- Variables de entorno respetadas: `CC`, `CXX`, `CFLAGS`, `CXXFLAGS`,
  `LDFLAGS`, `CPPFLAGS`, `PKG_CONFIG_PATH`, `PREFIX`.
