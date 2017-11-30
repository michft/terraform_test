## Ouch, read docs wrong with local and remote exec, hope remote exec is correct / wanted provisioner.

## Should be in separate files but required in single file setup.
variable "bucket_name" {
  description = "the command line bucketname"
  default = ""
}

variable "aws_access_key_id" {
  description = "the user aws access key"
  default = ""
}

variable "aws_secret_access_key" {
  description = "the user aws secret key"
  default = ""
}

variable "region" {
  default = "ap-southeast-2"
}

variable "key_name" {
  description = "The aws ssh key name."
  default = "companyx_key"
}

variable "key_file" {
  description = "The ssh public key for using with the cloud provider."
  default = "~/.ssh/id_rsa.pub"
}

variable "companyx_ami" {
  # AWS AMI (HVM), SSD Volume Type in ap_southeast_2
  default = "ami-ff4ea59d"

}

provider "aws" {
  access_key = "${var.aws_access_key_id}"
  secret_key = "${var.aws_secret_access_key}"
  region     = "${var.region}"

}

data "aws_availability_zones" "all" {}



## Actual Site file

/* SSH key pair */
resource "aws_key_pair" "ec2" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.key_file)}"
}


resource "aws_vpc" "companyx_vpc" {
  cidr_block = "10.0.0.0/16"

  tags {
    name = "companyx-vpc"
  }
}

resource "aws_nat_gateway" "nat" {
    allocation_id = "${aws_eip.companyx_eip.id}"
    subnet_id = "${aws_subnet.companyx_subnet.id}"
    depends_on = ["aws_internet_gateway.gw"]
}


# Associate subnet public_subnet_eu_west_1a to public route table
#resource "aws_route_table_association" "public_association" {
#    subnet_id = "${aws_subnet.companyx_subnet.id}"
#    route_table_id = "${aws_vpc.companyx_vpc.main_route_table_id}"
#}



resource "aws_eip" "companyx_eip" {
  vpc      = true
  depends_on = ["aws_internet_gateway.gw"]
}


resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.companyx_vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.gw.id}"
}




resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.companyx_vpc.id}"
  tags {
    Name = "InternetGateway"
  }
}



resource "aws_subnet" "companyx_subnet" {
  vpc_id                  = "${aws_vpc.companyx_vpc.id}"
  availability_zone       = "${data.aws_availability_zones.all.names[1]}"
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = "true"
}

resource "aws_sqs_queue" "companyx-queue" {
  name                        = "terraform-queue"
}

resource "aws_autoscaling_group" "companyx_autosg" {
  launch_configuration = "${aws_launch_configuration.companyx_lc.name}"
  vpc_zone_identifier = ["${aws_subnet.companyx_subnet.id}"]

  min_size = 1
  max_size = 1

  wait_for_capacity_timeout = "5m"

tag {
    key                 = "Name"
    value               = "companyx-autosg"
    propagate_at_launch = true
  }
}


resource "aws_route_table_association" "public_subnet_assoc" {
    subnet_id = "${aws_subnet.companyx_subnet.id}"
    route_table_id = "${aws_vpc.companyx_vpc.main_route_table_id}"
}


resource "aws_launch_configuration" "companyx_lc" {
  image_id      = "${var.companyx_ami}"
  instance_type = "t2.micro"
  iam_instance_profile = "${aws_iam_instance_profile.profile.arn}"
  key_name = "${aws_key_pair.ec2.key_name}"

  user_data = <<EOF
#!/bin/bash

#exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

set -xe

mkdir -p /root/tmp
cd /root/tmp

echo "IPv4: " > data.txt
wget http\:\/\/169.254.169.254\/latest\/meta-data\/local-ipv4 -O ->> data.txt
echo "

Hostname: " >> data.txt
wget http\:\/\/169.254.169.254\/latest\/meta-data\/hostname -O ->> data.txt
echo "

Reservation ID: " >> data.txt
wget http\:\/\/169.254.169.254\/latest\/meta-data\/reservation-id -O ->> data.txt
echo "
" >> data.txt
aws s3 sync . s3\:\/\/${aws_s3_bucket.companyx.id}\/

exit 0
EOF

  lifecycle {
    create_before_destroy = true
  }

}


output "info" {
  value = {
    "terraform.env" = "${terraform.env}",
    "bucket.bucket_domain_name" = "${aws_s3_bucket.companyx.bucket_domain_name}"
    "bucket.id" = "${aws_s3_bucket.companyx.id}"
    "bucket.arn" = "${aws_s3_bucket.companyx.arn}"
  }
}

resource "aws_iam_role" "role" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "s3_policy" {
  role = "${aws_iam_role.role.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::*"
      ]
    }
  ]

}
EOF
}

resource "aws_iam_instance_profile" "profile" {
  role = "${aws_iam_role.role.name}"
}

resource "aws_s3_bucket" "companyx" {
  bucket = "${var.bucket_name}"
  acl    = "private"

  tags {
    Name        = "My companyx bucket"
    Environment = "Job test"
  }
}

