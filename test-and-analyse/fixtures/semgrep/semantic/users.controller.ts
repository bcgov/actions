import { Controller, Delete, Get, Patch, Post, Put, UseGuards } from '@nestjs/common';

@Controller('users')
export class UsersController {
  @Get()
  findAll() {
    return [];
  }

  @Post()
  create() {
    return {};
  }

  @Post('login')
  login() {
    return {};
  }

  @UseGuards(JwtAuthGuard)
  @Put(':id')
  update() {
    return {};
  }

  @Public()
  @Delete(':id')
  remove() {
    return {};
  }
}

@UseGuards(JwtAuthGuard)
@Controller('orders')
export class OrdersController {
  @Patch(':id')
  patch() {
    return {};
  }
}
