FROM ubuntu:latest
ENV TZ=Europe/Amsterdam
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y libcapture-tiny-perl libxml-libxml-perl libxml-parser-perl libxml-bare-perl libtext-wagnerfischer-perl \
    libconfig-simple-perl libdate-calc-perl libtext-iconv-perl
