## Nextcloud + OnlyOffice + Let´s Encrypt + Nginx + Samba + Cron + Redis + LibreSign

This docker already has everything you need.

## Requirements

* Latest version of docker
* Docker compose


## Installation

1. Clone the most recent version of this repository:

    `` ''
    git clone https://github.com/Ripper/docker-nextcloud-onlyoffice/
    cd docker-onlyoffice-nextcloud
    `` ''
2. Change the settings within the ./config folder

3. Build and download:

    `` ''
    docker-compose build --pull
    `` ''

4. Run docker compose:

    `` ''
    docker-compose up -d
    `` ''

    ** NOTE **: Please wait for the certificates to be generated.

5. Now start the browser and enter the address of the web server. The Nextcloud wizard web page will open. Enter all the necessary data to complete the wizard.

6. Go to the project folder and run the `set_configuration.sh` script:

    ** NOTE **: run the file with ** root ** privileges.

    `` ''
    sudo bash set_config.sh
    `` ''
That's it, you already have your own Nextcloud server with onlyoffice included and the SAMBA modules, cron among others, ready to go.

[1]: http://dev.onlyoffice.org
[2]: https://github.com/ONLYOFFICE/DocumentServer
[3]: http://stackoverflow.com/questions/tagged/onlyoffice


------------------------------------------------------------------------------------------------------------------------------------------------

## Nextcloud + OnlyOffice + Let´s Encrypt + Nginx + Samba + Cron

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
2. Cambiar las configuraciones dentro de la carpeta ./config

3. Contruir y descargar:

    ```
    docker-compose build --pull
    ```

4. Correr docker compose:

    ```
    docker-compose up -d
    ```

    **NOTA**: espere a que se generen los certificados.

5. Ahora inicie el navegador e ingrese la dirección del servidor web. Se abrirá la página web del asistente de Nextcloud. Ingrese todos los datos necesarios para completar el asistente. 

6. Go to the project folder and run the `set_configuration.sh` script:

    **NOTA**: ejecute el archivo con privilegios **root**.

    ```
    sudo bash set_config.sh
    ```
Eso es todo, ya tienes tu propio servidor Nextcloud con onlyoffice incluido y los modulos de SAMBA, cron entre otros, ya listos.

[1]: http://dev.onlyoffice.org
[2]: https://github.com/ONLYOFFICE/DocumentServer
[3]: http://stackoverflow.com/questions/tagged/onlyoffice
