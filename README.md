## Nextcloud + OnlyOffice + Let's Encrypt + Nginx + Samba + Cron + Redis + (optional libresign)

This docker already has everything you need.

## Requirements

* Latest version of docker
* Docker compose 


## Facility

1. Clone the most recent version of this repository:

    ```
    git clone https://github.com/Destripador/docker-nextcloud-onlyoffice/
    cd docker-onlyoffice-nextcloud
    ```
2. Change the configurations within the ./config folder, it is important to add the configurations to avoid installation problems.
    - database configurations
      ./config/mariadb/db.env

    - Configurations nextcloud
      ./config/nextcloud/config.env

    - Let's encrypt
      ./config/nginx/web.env


4. Build and download:

    ```
    docker-compose build --pull
    ```

5. Run docker compose:

    ```
    docker-compose up -d
    ```

    **NOTE**: Please wait for the certificates to be generated.

6. Now launch the browser and enter the web server address or localhost from the same server, Nextcloud wizard web page will open. Enter all necessary data to complete the wizard. 

7. Inside the project folder, run `set_config.sh` script:

    **NOTE**: Run the file with **root** privileges.

    ```
    sudo bash set_config.sh
    ```
That's all, you now have your own Nextcloud server with onlyoffice included and the SAMBA, cron, and other modules, ready.

[1]: http://dev.onlyoffice.org
[2]: https://github.com/ONLYOFFICE/DocumentServer
[3]: http://stackoverflow.com/questions/tagged/onlyoffice
------------------------------------------------------------------------------------------------------------------------------------------------

## Nextcloud + OnlyOffice + Let´s Encrypt + Nginx + Samba + Cron + Redis + (Opcional libresign)

Este docker ya tiene todo lo que necesitas.

## Requerimentos

* Ultima version de docker
* Docker compose 


## Instalacion

1. Clonar la version mas reciente de este repositorio:

    ```
    git clone https://github.com/Destripador/docker-nextcloud-onlyoffice/
    cd docker-onlyoffice-nextcloud
    ```
2. Cambiar las configuraciones dentro de la carpeta ./config, es importante agregar las configuraciones para evitar problemas de instalacion.
    - configuraciones base de datos
      ./config/mariadb/db.env

    - Configurations nextcloud
      ./config/nextcloud/config.env

    - Lets encrypt
      ./config/nginx/web.env


4. Contruir y descargar:

    ```
    docker-compose build --pull
    ```

5. Correr docker compose:

    ```
    docker-compose up -d
    ```

    **NOTA**: espere a que se generen los certificados.

6. Ahora inicie el navegador e ingrese la dirección del servidor web o localhost desde el mismo servidor, Se abrirá la página web del asistente de Nextcloud. Ingrese todos los datos necesarios para completar el asistente. 

7. Dentro de la carpeta del proyecto, corre `set_config.sh` script:

    **NOTA**: ejecute el archivo con privilegios **root**.

    ```
    sudo bash set_config.sh
    ```
Eso es todo, ya tienes tu propio servidor Nextcloud con onlyoffice incluido y los modulos de SAMBA, cron entre otros, ya listos.

[1]: http://dev.onlyoffice.org
[2]: https://github.com/ONLYOFFICE/DocumentServer
[3]: http://stackoverflow.com/questions/tagged/onlyoffice
