# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanypar <chanypar@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/19 10:15:07 by chanypar          #+#    #+#              #
#    Updated: 2026/10/19 10:15:08 by chanypar         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash
set -e

# K3s Server 설치
curl -sfL https://get.k3s.io | sh -s - server \
  --node-ip 192.168.56.110

echo "K3s installation completed"