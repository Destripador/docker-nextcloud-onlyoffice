# Nextcloud + OnlyOffice + Let's Encrypt + Nginx + Samba + Cron + Redis + (Optional: LibreSign)

This Docker setup includes everything needed to deploy a Nextcloud server with OnlyOffice, SSL certificate with Let's Encrypt, Nginx as a reverse proxy, Samba for file sharing, Cron for scheduled tasks, and Redis for performance improvement. Additionally, you can optionally add LibreSign for document signing.

---

## Requirements

* Latest version of **Docker**
* **Docker Compose**

---

## Installation

### 1. Clone the latest repository

```sh
  git clone https://github.com/Destripador/docker-nextcloud-onlyoffice/
  cd docker-nextcloud-onlyoffice
```

### 2. Configure the necessary files

Before proceeding with the installation, it is **important** to configure the files inside the `./config` folder to avoid issues.

- **Database configurations**
  - File: `./config/mariadb/db.env`

- **Nextcloud configurations**
  - File: `./config/nextcloud/config.env`

- **Let's Encrypt configurations**
  - File: `./config/nginx/web.env`

> ⚠️ **IMPORTANT:** Verify and customize these configurations before continuing.

### 3. Build and pull Docker images

Run the following command to build and pull the necessary images:

```sh
  docker-compose build --pull
```

### 4. Start the containers with Docker Compose

```sh
  docker-compose up -d
```

> **Note:** Wait for the SSL certificates to be generated before continuing.

### 5. Access the Nextcloud web interface

Open a web browser and enter the address of the web server (or `localhost` if you are on the same machine). The Nextcloud installation wizard will open.

Follow the wizard steps and enter the necessary information to complete the installation.

### 6. Run the configuration script

Inside the project folder, run the `set_config.sh` script to complete the configuration.

> ⚠️ **Run this file with root privileges:**

```sh
  sudo bash set_config.sh
```

---

## Done!

Your Nextcloud server with OnlyOffice, Samba, Cron, Redis, and more is installed and ready to use. 🎉

### 7. Configure OnlyOffice

If necessary, configure the OnlyOffice service. This container is already prepared to auto-configure, but if you need to change the connection password with OnlyOffice, modify the `docker-compose.yml`.

```yaml
######## ONLYOFFICE ########
    environment:
      JWT_ENABLED: 'true'
      JWT_SECRET: 'SuperSecretPasskeyThatNoOneKnows'
      JWT_HEADER: 'AuthorizationJwt'
      JWT_IN_BODY: 'true'
```

Change `JWT_SECRET` which is the key used for automatic connection.

Don't forget to verify the connection with the server from the OnlyOffice module in Nextcloud.

Below is a reference image for the server configuration:

![Server Configuration](https://raw.githubusercontent.com/Destripador/docker-nextcloud-onlyoffice/main/img/server-setup.png)

If you have any questions or issues, check the OnlyOffice and Nextcloud documentation:

- [OnlyOffice Developers](http://dev.onlyoffice.org)
- [DocumentServer Repository on GitHub](https://github.com/ONLYOFFICE/DocumentServer)
- [Frequently Asked Questions on Stack Overflow](http://stackoverflow.com/questions/tagged/onlyoffice)





-----------------------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------------------




# Nextcloud + OnlyOffice + Let's Encrypt + Nginx + Samba + Cron + Redis + (Opcional: LibreSign)

Este Docker ya incluye todo lo necesario para desplegar un servidor Nextcloud con OnlyOffice, certificado SSL con Let's Encrypt, Nginx como proxy inverso, Samba para compartir archivos, Cron para tareas programadas y Redis para mejorar el rendimiento. Además, puedes añadir opcionalmente LibreSign para la firma de documentos.

---

## Requisitos

* Última versión de **Docker**
* **Docker Compose**

---

## Instalación

### 1. Clonar el repositorio más reciente

```sh
  git clone https://github.com/Destripador/docker-nextcloud-onlyoffice/
  cd docker-nextcloud-onlyoffice
```

### 2. Configurar los archivos necesarios

Antes de proceder con la instalación, es **importante** configurar los archivos dentro de la carpeta `./config` para evitar problemas.

- **Configuraciones de la base de datos**
  - Archivo: `./config/mariadb/db.env`

- **Configuraciones de Nextcloud**
  - Archivo: `./config/nextcloud/config.env`

- **Configuraciones de Let's Encrypt**
  - Archivo: `./config/nginx/web.env`

> ⚠️ **IMPORTANTE:** Verifica y personaliza estas configuraciones antes de continuar.

### 3. Construir y descargar las imágenes Docker

Ejecuta el siguiente comando para construir y descargar las imágenes necesarias:

```sh
  docker-compose build --pull
```

### 4. Iniciar los contenedores con Docker Compose

```sh
  docker-compose up -d
```

> **Nota:** Espera a que se generen los certificados SSL antes de continuar.

### 5. Acceder a la interfaz web de Nextcloud

Abre un navegador web e ingresa la dirección del servidor web (o `localhost` si estás en la misma máquina). Se abrirá el asistente de instalación de Nextcloud.

Sigue los pasos del asistente e ingresa los datos necesarios para completar la instalación.

### 6. Ejecutar el script de configuración

Dentro de la carpeta del proyecto, ejecuta el script `set_config.sh` para completar la configuración.

> ⚠️ **Ejecuta este archivo con privilegios root:**

```sh
  sudo bash set_config.sh
```

---

## ¡Listo!

Tu servidor Nextcloud con OnlyOffice, Samba, Cron, Redis y más está instalado y listo para usarse. 🎉


### 5. Configura Onlyoffice
De ser necesario, configura el servicio de only office, este contenedor ya esta preparado para auto configurarse, pero si es requerido cambiar la contraseña de
conexion con onlyoffice, modifica el docker-compose.yml

```yaml
######## ONLYOFFICE ########
    environment:
      JWT_ENABLED: 'true'
      JWT_SECRET: 'SuperSecretPasskeyThatNoOneKnows'
      JWT_HEADER: 'AuthorizationJwt'
      JWT_IN_BODY: 'true'
```

cambiando JWT_SECRET que es la llave con la que se conecta de manera automatica.

no olvides verificar la conexion con el servido desde el modulo de onlyoffice en nextcloud.


A continuación, se muestra una imagen de referencia para la configuración del servidor:

![Server Configuration](https://raw.githubusercontent.com/Destripador/docker-nextcloud-onlyoffice/main/img/server-setup.png)


Si tienes dudas o problemas, revisa la documentación de OnlyOffice y Nextcloud:

- [OnlyOffice Developers](http://dev.onlyoffice.org)
- [Repositorio de DocumentServer en GitHub](https://github.com/ONLYOFFICE/DocumentServer)
- [Preguntas frecuentes en Stack Overflow](http://stackoverflow.com/questions/tagged/onlyoffice)

