<template>
  <div class="about">
    <video id="bgvid" autoplay muted loop>
      <source src="../../123.mp4" type="video/mp4" />
    </video>
    <el-form
      :model="loginForm"
      status-icon
      :rules="rules"
      ref="loginForm"
      label-width="100px"
      class="demo-loginForm"
    >
      <h1 style="display:flex;justify-content:center">管理系统登陆</h1>
      <el-form-item label="用户名" prop="username">
        <el-input
          type="text"
          v-model="loginForm.username"
          autocomplete="off"
        ></el-input>
      </el-form-item>
      <el-form-item label="密码" prop="password">
        <el-input
          type="password"
          v-model="loginForm.password"
          autocomplete="off"
        ></el-input>
      </el-form-item>
      <el-form-item>
        <el-button type="primary" @click="submitForm('loginForm')"
          >提交</el-button
        >
      </el-form-item>
    </el-form>
  </div>
</template>
<script>
// 登入逻辑的实现
// 1，收集用户输入的username和password给后端
// 2，登入通过后把后端返回的token存在本地
// 3，每次请求的时候携带token到请求头 authorization
// 4，展示token效验正确的数据
// 5，校验不通过返回登陆页
import { login } from "@/api";
import { mapMutations } from "vuex";
export default {
  data() {
    var validateUsername = (rule, value, callback) => {
      // console.log(rule);
      // console.log(value);
      if (!value) {
        callback("请输入用户名");
      } else {
        callback();
      }
      // if (value === '') {
      //   callback(new Error('请输入用户名'));
      // } else {
      //   if (this.loginForm.username !== '') {
      //     this.$refs.loginForm.validateField('password');
      //   }
      //   callback();
      // }
    };
    var validatePass = (rule, value, callback) => {
      // console.log(value);
      if (!value) {
        callback("请输入密码");
      } else {
        callback();
      }
    };
    return {
      loginForm: {
        username: "",
        password: ""
      },
      rules: {
        username: [{ validator: validateUsername, trigger: "blur" }],
        password: [{ validator: validatePass, trigger: "blur" }]
      }
    };
  },
  methods: {
    ...mapMutations(["SET_USERINFO"]),
    submitForm(formName) {
      // console.log(this.loginForm);
      // console.log(this.$refs);
      // console.log(this.$refs[formName]);
      // console.log(this.$refs.loginForm.validate());
      this.$refs[formName].validate(valid => {
        if (valid) {
          const loading = this.$loading({
            lock: true,
            text: "正在登陆",
            spinner: "el-icon-loading",
            background: "rgba(0, 0, 0, 0.7)"
          });

          let { username, password } = this.loginForm;
          login(username, password)
            .then(res => {
              loading.close();
              if (res.data.state) {
                this.$message.success("登陆成功");
                localStorage.setItem("qf2005-token", res.data.token);
                localStorage.setItem(
                  "qf2005-userInfo",
                  JSON.stringify(res.data.userInfo)
                );
                this.SET_USERINFO(res.data.userInfo);
                this.$router.push("/home");
              } else {
                this.$message.error("用户名或者密码错误");
              }
            })
            .catch(err => {
              console.log(err);
            });
        } else {
          console.log("error submit!!");
          return false;
        }
      });
    }
  }
};
</script>
<style scoped>
.about {
  width: 400px;
  position: absolute;
  right: 150px;
  top: 200px;
}
.el-form {
  width: 400px;
  height: 250px;
}
#bgvid {
  position: fixed;
  right: 0;
  bottom: 0;
  min-width: 100%;
  min-height: 100%;
  width: auto;
  height: auto;
  z-index: -100;
  background-size: cover;
}
</style>
