import Vue from "vue";
import App from "./App.vue";
import router from "./router";
import store from "./store";
import "@/assets/styles/el-reset.css";
import "@/assets/styles/base.css";
import ElementUI from "element-ui";
import "element-ui/lib/theme-chalk/index.css";
Vue.use(ElementUI);
// Vue.config.productionTip = false;
//路由前置钩子(导航守卫)
router.beforeEach((to, from, next) => {
  // console.log(to);
  // console.log(from);
  let token = localStorage.getItem("qf2005-token");
  if (token) {
    next();
  } else {
    if (to.path === "/login") {
      next();
    } else {
      next({ path: "/login" });
    }
  }
});
new Vue({
  router,
  store,
  render: h => h(App)
}).$mount("#app");
