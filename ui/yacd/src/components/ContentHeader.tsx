import React from 'react';

import s0 from './ContentHeader.module.scss';

type Props = {
  children?: React.ReactNode;
};

function ContentHeader({ children }: Props) {
  return <div className={s0.root}>{children}</div>;
}

export default React.memo(ContentHeader);
