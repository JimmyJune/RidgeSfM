FROM nvidia/cuda:10.2-cudnn8-runtime-ubuntu18.04

LABEL authors="Christoph Schranz <christoph.schranz@salzburgresearch.at>, Mathematical Michael <consistentbayes@gmail.com>"
# This is a concatenated Dockerfile, the maintainers of subsequent sections may vary.
RUN chmod 1777 /tmp && chmod 1777 /var/tmp

############################################################################
#################### Dependency: jupyter/base-image ########################
############################################################################

# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

# Ubuntu 20.04 (focal)
# https://hub.docker.com/_/ubuntu/?tab=tags&name=focal
# OS/ARCH: linux/amd64
ARG ROOT_CONTAINER=ubuntu:focal-20201106@sha256:4e4bc990609ed865e07afc8427c30ffdddca5153fd4e82c20d8f0783a291e241


LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"
ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

# Fix DL4006
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# ---- Miniforge installer ----
# Default values can be overridden at build time
# (ARGS are in lower case to distinguish them from ENV)
# Check https://github.com/conda-forge/miniforge/releases
# Conda version
ARG conda_version="4.9.2"
# Miniforge installer patch version
ARG miniforge_patch_number="0"
# Miniforge installer architecture
ARG miniforge_arch="x86_64"
# Python implementation to use 
# can be either Miniforge3 to use Python or Miniforge-pypy3 to use PyPy
ARG miniforge_python="Miniforge3"

# Miniforge archive to install
ARG miniforge_version="${conda_version}-${miniforge_patch_number}"
# Miniforge installer
ARG miniforge_installer="${miniforge_python}-${miniforge_version}-Linux-${miniforge_arch}.sh"
# Miniforge checksum
ARG miniforge_checksum="6321775eb2c02d7f51d3a9004ce0be839099f126f4099c781531428536669560"

# Install all OS dependencies for notebook server that starts but lacks all
# features (e.g., download as all possible file formats)
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update \
 && apt-get install -yq --no-install-recommends \
    wget \
    ca-certificates \
    sudo \
    locales \
    fonts-liberation \
    run-one \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER=$NB_USER \
    NB_UID=$NB_UID \
    NB_GID=$NB_GID \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH=$CONDA_DIR/bin:$PATH \
    HOME=/home/$NB_USER \
    CONDA_VERSION="${conda_version}" \
    MINIFORGE_VERSION="${miniforge_version}"

# Copy a script that we will use to correct permissions after running certain commands
COPY fix-permissions /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions

# Enable prompt color in the skeleton .bashrc before creating the default NB_USER
# hadolint ignore=SC2016
RUN sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc && \
   # Add call to conda init script see https://stackoverflow.com/a/58081608/4413446
   echo 'eval "$(command conda shell.bash hook 2> /dev/null)"' >> /etc/skel/.bashrc 

# Create NB_USER with name jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su && \
    sed -i.bak -e 's/^%admin/#%admin/' /etc/sudoers && \
    sed -i.bak -e 's/^%sudo/#%sudo/' /etc/sudoers && \
    useradd -m -s /bin/bash -N -u $NB_UID $NB_USER && \
    mkdir -p $CONDA_DIR && \
    chown $NB_USER:$NB_GID $CONDA_DIR && \
    chmod g+w /etc/passwd && \
    fix-permissions $HOME && \
    fix-permissions $CONDA_DIR

USER $NB_UID
ARG PYTHON_VERSION=default

# Setup work directory for backward-compatibility
RUN mkdir "/home/$NB_USER/work" && \
    fix-permissions "/home/$NB_USER"

# Install conda as jovyan and check the sha256 sum provided on the download site
WORKDIR /tmp

# Prerequisites installation: conda, pip, tini
RUN wget --quiet "https://github.com/conda-forge/miniforge/releases/download/${miniforge_version}/${miniforge_installer}" && \
    echo "${miniforge_checksum} *${miniforge_installer}" | sha256sum --check && \
    /bin/bash "${miniforge_installer}" -f -b -p $CONDA_DIR && \
    rm "${miniforge_installer}" && \
    # Conda configuration see https://conda.io/projects/conda/en/latest/configuration.html
    echo "conda ${CONDA_VERSION}" >> $CONDA_DIR/conda-meta/pinned && \
    conda config --system --set auto_update_conda false && \
    conda config --system --set show_channel_urls true && \
    if [ ! $PYTHON_VERSION = 'default' ]; then conda install --yes python=$PYTHON_VERSION; fi && \
    conda list python | grep '^python ' | tr -s ' ' | cut -d '.' -f 1,2 | sed 's/$/.*/' >> $CONDA_DIR/conda-meta/pinned && \
    conda install --quiet --yes \
    "conda=${CONDA_VERSION}" \
    'pip' \
    'tini=0.18.0' && \
    conda update --all --quiet --yes && \
    conda list tini | grep tini | tr -s ' ' | cut -d ' ' -f 1,2 >> $CONDA_DIR/conda-meta/pinned && \
    conda clean --all -f -y && \
    rm -rf /home/$NB_USER/.cache/yarn && \
    fix-permissions $CONDA_DIR && \
    fix-permissions /home/$NB_USER

# Install Jupyter Notebook, Lab, and Hub
# Generate a notebook server config
# Cleanup temporary files
# Correct permissions
# Do all this in a single RUN command to avoid duplicating all of the
# files across image layers when the permissions change
RUN conda install --quiet --yes \
    'notebook=6.1.6' \
    'jupyterhub=1.3.0' \
    'jupyterlab=2.2.9' && \
    conda clean --all -f -y && \
    npm cache clean --force && \
    jupyter notebook --generate-config && \
    rm -rf $CONDA_DIR/share/jupyter/lab/staging && \
    rm -rf /home/$NB_USER/.cache/yarn && \
    fix-permissions $CONDA_DIR && \
    fix-permissions /home/$NB_USER

EXPOSE 8888

# Configure container startup
ENTRYPOINT ["tini", "-g", "--"]
CMD ["start-notebook.sh"]

# Copy local files as late as possible to avoid cache busting
COPY start.sh start-notebook.sh start-singleuser.sh /usr/local/bin/
# Currently need to have both jupyter_notebook_config and jupyter_server_config to support classic and lab
COPY jupyter_notebook_config.py /etc/jupyter/

# Fix permissions on /etc/jupyter as root
USER root

# Prepare upgrade to JupyterLab V3.0 #1205
RUN sed -re "s/c.NotebookApp/c.ServerApp/g" \
    /etc/jupyter/jupyter_notebook_config.py > /etc/jupyter/jupyter_server_config.py

RUN fix-permissions /etc/jupyter/

# Switch back to jovyan to avoid accidental container runs as root
USER $NB_UID

WORKDIR $HOME

############################################################################
################# Dependency: jupyter/minimal-notebook #####################
############################################################################

# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"

USER root

# Install all OS dependencies for fully functional notebook server
RUN apt-get update && apt-get install -yq --no-install-recommends \
    build-essential \
    vim-tiny \
    git \
    inkscape \
    libsm6 \
    libxext-dev \
    libxrender1 \
    lmodern \
    netcat \
    # ---- nbconvert dependencies ----
    texlive-xetex \
    texlive-fonts-recommended \
    texlive-plain-generic \
    # ----
    tzdata \
    unzip \
    nano-tiny \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create alternative for nano -> nano-tiny
RUN update-alternatives --install /usr/bin/nano nano /bin/nano-tiny 10

# Switch back to jovyan to avoid accidental container runs as root
USER $NB_UID

############################################################################
################# Dependency: jupyter/scipy-notebook #######################
############################################################################

# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"

USER root

# ffmpeg for matplotlib anim & dvipng+cm-super for latex labels
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg dvipng cm-super && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

USER $NB_UID

# Install Python 3 packages
RUN conda install --quiet --yes \
    'beautifulsoup4=4.9.*' \
    'conda-forge::blas=*=openblas' \
    'bokeh=2.2.*' \
    'bottleneck=1.3.*' \
    'cloudpickle=1.6.*' \
    'cython=0.29.*' \
    'dask=2020.12.*' \
    'dill=0.3.*' \
    'h5py=3.1.*' \
    'ipywidgets=7.6.*' \
    'ipympl=0.5.*'\
    'matplotlib-base=3.3.*' \
    'numba=0.52.*' \
    'numexpr=2.7.*' \
    'pandas=1.1.*' \
    'patsy=0.5.*' \
    'protobuf=3.14.*' \
    'pytables=3.6.*' \
    'scikit-image=0.18.*' \
    'scikit-learn=0.24.*' \
    'scipy=1.5.*' \
    'seaborn=0.11.*' \
    'sqlalchemy=1.3.*' \
    'statsmodels=0.12.*' \
    'sympy=1.7.*' \
    'vincent=0.4.*' \
    'widgetsnbextension=3.5.*'\
    'xlrd=1.2.*' \
    && \
    conda clean --all -f -y && \
    # Activate ipywidgets extension in the environment that runs the notebook server
    jupyter nbextension enable --py widgetsnbextension --sys-prefix && \
    # Also activate ipywidgets extension for JupyterLab
    # Check this URL for most recent compatibilities
    # https://github.com/jupyter-widgets/ipywidgets/tree/master/packages/jupyterlab-manager
    jupyter labextension install @jupyter-widgets/jupyterlab-manager@^2.0.0 --no-build && \
    jupyter labextension install @bokeh/jupyter_bokeh@^2.0.0 --no-build && \
    jupyter labextension install jupyter-matplotlib@^0.7.2 --no-build && \
    jupyter lab build -y && \
    jupyter lab clean -y && \
    npm cache clean --force && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    rm -rf "/home/${NB_USER}/.node-gyp" && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

# Install facets which does not have a pip or conda package at the moment
WORKDIR /tmp
RUN git clone https://github.com/PAIR-code/facets.git && \
    jupyter nbextension install facets/facets-dist/ --sys-prefix && \
    rm -rf /tmp/facets && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

# Import matplotlib the first time to build the font cache.
ENV XDG_CACHE_HOME="/home/${NB_USER}/.cache/"

RUN MPLBACKEND=Agg python -c "import matplotlib.pyplot" && \
    fix-permissions "/home/${NB_USER}"

USER $NB_UID

WORKDIR $HOME

############################################################################
########################## Dependency: gpulibs #############################
############################################################################

LABEL maintainer="Christoph Schranz <christoph.schranz@salzburgresearch.at>"

# Install Tensorflow, check compatibility here: https://www.tensorflow.org/install/gpu
# installation via conda leads to errors in version 4.8.2
RUN pip install --upgrade pip && \
    pip install --no-cache-dir "tensorflow-gpu>=2.1.*" && \
    pip install --no-cache-dir keras

# Install PyTorch with dependencies
RUN conda install --quiet --yes \
    pyyaml mkl mkl-include setuptools cmake cffi typing

# Check compatibility here: https://pytorch.org/get-started/locally/
RUN conda install --quiet --yes \
     pytorch \ 
     torchvision \
     cudatoolkit=10.1 -c pytorch
#    pip install torch_nightly -f https://download.pytorch.org/whl/nightly/cu90/torch_nightly.html && \
RUN pip install  --no-cache-dir torchviz


# Clean installation
RUN conda clean --all -f -y && \
    fix-permissions $CONDA_DIR && \
    fix-permissions /home/$NB_USER

  ############################################################################
  ############################ Useful packages ###############################
  ############################################################################
  
LABEL authors="Christoph Schranz <christoph.schranz@salzburgresearch.at>, Mathematical Michael <consistentbayes@gmail.com>"

USER root

RUN pip install --no-cache-dir ipyleaflet plotly==4.8.* "ipywidgets>=7.5"

# Install important packages and Graphviz
RUN set -ex \
 && buildDeps=' \
    graphviz==0.11 \
' \
 && apt-get update \
 && apt-get -y install htop apt-utils graphviz libgraphviz-dev openssh-client \
 && pip install --no-cache-dir $buildDeps

# Install various extensions
RUN fix-permissions $CONDA_DIR
RUN jupyter labextension install @jupyterlab/github
RUN jupyter labextension install jupyterlab-drawio
RUN jupyter labextension install jupyter-leaflet
RUN jupyter labextension install jupyterlab-plotly@4.8.1
RUN jupyter labextension install @jupyter-widgets/jupyterlab-manager
RUN pip install --no-cache-dir jupyter-tabnine==1.0.2  && \
  jupyter nbextension install --py jupyter_tabnine && \
  jupyter nbextension enable --py jupyter_tabnine && \
  jupyter serverextension enable --py jupyter_tabnine
RUN pip install --no-cache-dir jupyter_contrib_nbextensions \
 jupyter_nbextensions_configurator rise && \
  jupyter nbextension enable codefolding/main
RUN jupyter labextension install @ijmbarr/jupyterlab_spellchecker

RUN fix-permissions /home/$NB_USER

# Switch back to jovyan to avoid accidental container runs as root
USER $NB_UID

# Copy jupyter_notebook_config.json
COPY jupyter_notebook_config.json /etc/jupyter/
