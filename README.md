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

    **note**: espere a que se generen los certificados.

5. Now launch the browser and enter the webserver address. The Nextcloud wizard webpage will be opened. Enter all the necessary data to complete the wizard.

6. Go to the project folder and run the `set_configuration.sh` script:

    **Please note**: ejecute el archivo con privilegios **root**.

    ```
    sudo bash set_config.sh
    ```
Eso es todo, ya tienes tu propio servidor Nextcloud con onlyoffice incluido y los modulos de SAMBA, cron entre otros, ya listos.

[1]: http://dev.onlyoffice.org
[2]: https://github.com/ONLYOFFICE/DocumentServer
[3]: http://stackoverflow.com/questions/tagged/onlyoffice
