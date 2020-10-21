import Vue from "vue";
import Vuex from "vuex";

Vue.use(Vuex);

let userInfo = localStorage.getItem("qf2005-userInfo") || {};
userInfo = JSON.parse(userInfo);
export default new Vuex.Store({
  state: {
    userInfo
  },
  mutations: {
    SET_USERINFO(state, payload) {
      state.userInfo = payload;
    }
  },
  actions: {},
  modules: {}
});
